import Accelerate
import os

/// Stereo preamp + cascaded biquad EQ with optional dynamic bands.
/// `update` and `liveGains` run on any thread, `process` on the audio thread.
public final class EQProcessor: @unchecked Sendable {
    public let sampleRate: Double
    private let count: Int
    private let block = 64 // dynamic gains are re-evaluated this often (frames)
    private let attack = 0.005, release = 0.15 // seconds

    private let setup: vDSP_biquadm_Setup
    private let lock = OSAllocatedUnfairLock(initialState: Pending())
    private let pending: UnsafeMutablePointer<Band>  // guarded by lock
    private let liveLock = OSAllocatedUnfairLock()
    private let live: UnsafeMutablePointer<Double>   // guarded by liveLock: gain in use per band

    // Audio thread only.
    private let bands: UnsafeMutablePointer<Band>
    private let applied: UnsafeMutablePointer<Double>  // gain in use per band
    private let envelope: UnsafeMutablePointer<Double> // smoothed band level, dB
    private let detectors: [vDSP_biquad_Setup]
    private let detectorDelay: UnsafeMutablePointer<Float>
    private let section: UnsafeMutablePointer<Double>  // one section's coefficients, both channels
    private let gainFactor: UnsafeMutablePointer<Float>
    private let mono, detected, outL, outR: UnsafeMutablePointer<Float>
    private let xs: UnsafeMutablePointer<UnsafePointer<Float>>
    private let ys: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    private struct Pending { var dirty = false; var gain: Float = 1 }

    public init(sampleRate: Double, settings: EQSettings) {
        self.sampleRate = sampleRate
        count = settings.bands.count
        let flat = [Double](repeating: 0, count: 5 * count * 2).enumerated().map { $0.offset % 5 == 0 ? 1.0 : 0 }
        setup = vDSP_biquadm_CreateSetup(flat, vDSP_Length(count), 2)!
        detectors = (0..<settings.bands.count).map { _ in vDSP_biquad_CreateSetup(Biquad.identity.coefficients, 1)! }
        pending = .allocate(capacity: count)
        live = .allocate(capacity: count)
        bands = .allocate(capacity: count)
        applied = .allocate(capacity: count)
        envelope = .allocate(capacity: count)
        detectorDelay = .allocate(capacity: 4 * count)
        section = .allocate(capacity: 10)
        gainFactor = .allocate(capacity: 1)
        mono = .allocate(capacity: block)
        detected = .allocate(capacity: block)
        outL = .allocate(capacity: block)
        outR = .allocate(capacity: block)
        xs = .allocate(capacity: 2)
        ys = .allocate(capacity: 2)
        ys[0] = outL
        ys[1] = outR
        live.initialize(repeating: 0, count: count)
        applied.initialize(repeating: 0, count: count)
        envelope.initialize(repeating: -120, count: count)
        detectorDelay.initialize(repeating: 0, count: 4 * count)
        bands.initialize(from: settings.bands, count: count)
        pending.initialize(from: settings.bands, count: count)
        gainFactor.pointee = Self.linear(settings.preampDB)
        reload()
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
        detectors.forEach { vDSP_biquad_DestroySetup($0) }
        for p in [live, applied, envelope, section] { p.deallocate() }
        for p in [detectorDelay, gainFactor, mono, detected, outL, outR] { p.deallocate() }
        pending.deallocate()
        bands.deallocate()
        xs.deallocate()
        ys.deallocate()
    }

    public func update(_ settings: EQSettings) {
        precondition(settings.bands.count == count, "band count is fixed per processor")
        let gain = Self.linear(settings.preampDB)
        settings.bands.withUnsafeBufferPointer { new in
            lock.withLockUnchecked { state in
                pending.update(from: new.baseAddress!, count: count)
                state = Pending(dirty: true, gain: gain)
            }
        }
    }

    /// Gain each band is applying right now (dynamic bands move with the music).
    public func liveGains() -> [Double] {
        liveLock.withLockUnchecked { Array(UnsafeBufferPointer(start: live, count: count)) }
    }

    /// Filters `left` and `right` in place. Realtime safe: no allocation, never blocks.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let changed = lock.withLockIfAvailableUnchecked { state -> Bool in
            guard state.dirty else { return false }
            bands.update(from: pending, count: count)
            gainFactor.pointee = state.gain
            state.dirty = false
            return true
        }
        if changed == true { reload() }

        var done = 0
        while done < frames {
            let n = min(block, frames - done)
            let l = left + done, r = right + done
            vDSP_vsmul(l, 1, gainFactor, l, 1, vDSP_Length(n))
            vDSP_vsmul(r, 1, gainFactor, r, 1, vDSP_Length(n))
            followLevels(l, r, n)
            xs[0] = UnsafePointer(l)
            xs[1] = UnsafePointer(r)
            vDSP_biquadm(setup, xs, 1, ys, 1, vDSP_Length(n))
            l.update(from: outL, count: n)
            r.update(from: outR, count: n)
            done += n
        }
        liveLock.withLockIfAvailableUnchecked { live.update(from: applied, count: count) }
    }

    /// Measures each dynamic band's level in this block and moves its gain accordingly.
    private func followLevels(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        var haveMono = false
        for i in 0..<count where bands[i].dynamic && bands[i].enabled {
            if !haveMono {
                vDSP_vadd(l, 1, r, 1, mono, 1, vDSP_Length(n))
                var half: Float = 0.5
                vDSP_vsmul(mono, 1, &half, mono, 1, vDSP_Length(n))
                haveMono = true
            }
            vDSP_biquad(detectors[i], detectorDelay + 4 * i, mono, 1, detected, 1, vDSP_Length(n))
            var meanSquare: Float = 0
            vDSP_measqv(detected, 1, &meanSquare, vDSP_Length(n))
            let level = 10 * log10(Double(meanSquare) + 1e-12)
            let tau = level > envelope[i] ? attack : release
            envelope[i] = level + (envelope[i] - level) * exp(-Double(n) / (sampleRate * tau))
            let target = bands[i].dynamicGain(levelDB: envelope[i])
            if abs(target - applied[i]) > 0.01 {
                applied[i] = target
                setSection(i)
            }
        }
    }

    /// After settings change: static bands take their gain, detectors follow the band's frequency.
    private func reload() {
        for i in 0..<count {
            let band = bands[i]
            if band.dynamic {
                band.withDetector(sampleRate) { vDSP_biquad_SetCoefficientsDouble(detectors[i], $0, 0, 1) }
                applied[i] = band.dynamicGain(levelDB: envelope[i])
            } else {
                applied[i] = band.gainDB
            }
            setSection(i)
        }
    }

    private func setSection(_ i: Int) {
        var band = bands[i]
        band.gainDB = applied[i]
        let c = band.biquad(sampleRate: sampleRate)
        for ch in 0..<2 {
            section[5 * ch] = c.b0; section[5 * ch + 1] = c.b1; section[5 * ch + 2] = c.b2
            section[5 * ch + 3] = c.a1; section[5 * ch + 4] = c.a2
        }
        vDSP_biquadm_SetCoefficientsDouble(setup, section, vDSP_Length(i), 0, 1, 2)
    }

    static func linear(_ db: Double) -> Float { Float(pow(10, db / 20)) }
}

private extension Band {
    /// Passes the band-pass coefficients without allocating (audio thread).
    func withDetector(_ sampleRate: Double, _ body: (UnsafePointer<Double>) -> Void) {
        let c = Biquad.bandPass(freq: freq, q: q, sampleRate: sampleRate)
        var tuple = (c.b0, c.b1, c.b2, c.a1, c.a2)
        withUnsafePointer(to: &tuple) { $0.withMemoryRebound(to: Double.self, capacity: 5) { body($0) } }
    }
}
