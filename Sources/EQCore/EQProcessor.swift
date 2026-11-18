import Accelerate
import os

/// Stereo preamp + cascaded biquad EQ. `update` runs on any thread, `process` on the audio thread.
public final class EQProcessor: @unchecked Sendable {
    public let sampleRate: Double
    private let sections: Int
    private let maxFrames = 4096
    private let setup: vDSP_biquadm_Setup
    private let gainFactor: UnsafeMutablePointer<Float> // audio thread only
    private let pending: UnsafeMutablePointer<Double>    // guarded by lock
    private let lock = OSAllocatedUnfairLock(initialState: Pending())
    private let xs: UnsafeMutablePointer<UnsafePointer<Float>>
    private let ys: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outL, outR: UnsafeMutablePointer<Float>

    private struct Pending { var dirty = false; var gain: Float = 1 }

    public init(sampleRate: Double, settings: EQSettings) {
        self.sampleRate = sampleRate
        sections = settings.bands.count
        let coeffs = Self.coefficients(settings, sampleRate)
        setup = vDSP_biquadm_CreateSetup(coeffs, vDSP_Length(sections), 2)!
        pending = .allocate(capacity: coeffs.count)
        gainFactor = .allocate(capacity: 1)
        gainFactor.pointee = Self.linear(settings.preampDB)
        outL = .allocate(capacity: maxFrames)
        outR = .allocate(capacity: maxFrames)
        xs = .allocate(capacity: 2)
        ys = .allocate(capacity: 2)
        ys[0] = outL
        ys[1] = outR
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
        pending.deallocate()
        gainFactor.deallocate()
        outL.deallocate()
        outR.deallocate()
        xs.deallocate()
        ys.deallocate()
    }

    public func update(_ settings: EQSettings) {
        precondition(settings.bands.count == sections, "band count is fixed per processor")
        let coeffs = Self.coefficients(settings, sampleRate)
        let gain = Self.linear(settings.preampDB)
        lock.withLock { state in
            pending.update(from: coeffs, count: coeffs.count)
            state = Pending(dirty: true, gain: gain)
        }
    }

    /// Filters `left` and `right` in place. Realtime safe: no allocation, never blocks.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLockIfAvailable { state in
            guard state.dirty else { return }
            // shortcut: coefficients jump instead of ramping; switch to vDSP_biquadm_SetTargetsDouble if slider drags click.
            vDSP_biquadm_SetCoefficientsDouble(setup, pending, 0, 0, vDSP_Length(sections), 2)
            gainFactor.pointee = state.gain
            state.dirty = false
        }
        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            let l = left + done, r = right + done
            vDSP_vsmul(l, 1, gainFactor, l, 1, vDSP_Length(n))
            vDSP_vsmul(r, 1, gainFactor, r, 1, vDSP_Length(n))
            xs[0] = UnsafePointer(l)
            xs[1] = UnsafePointer(r)
            vDSP_biquadm(setup, xs, 1, ys, 1, vDSP_Length(n))
            l.update(from: outL, count: n)
            r.update(from: outR, count: n)
            done += n
        }
    }

    /// Section-major, one copy per channel: [s0c0, s0c1, s1c0, ...] × 5 coefficients.
    static func coefficients(_ settings: EQSettings, _ sampleRate: Double) -> [Double] {
        settings.bands.flatMap { band -> [Double] in
            let c = band.biquad(sampleRate: sampleRate).coefficients
            return c + c
        }
    }

    static func linear(_ db: Double) -> Float { Float(pow(10, db / 20)) }
}
