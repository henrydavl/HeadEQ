import Accelerate
import os

/// Live spectrum of what is playing. `push` runs on the audio thread; everything else on the main thread.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let size = 4096
    public static let floorDB: Float = -90
    public var sampleRate = 48_000.0

    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: size) // guarded by lock
    private let lock = OSAllocatedUnfairLock(initialState: 0)                // next write position
    private let dft = try! vDSP.DiscreteFourierTransform(count: size, direction: .forward, transformType: .complexReal, ofType: Float.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private var shown: [Float] = []

    public init() { ring.initialize(repeating: 0, count: Self.size) }

    deinit { ring.deallocate() }

    /// Audio thread. Never blocks: if the UI is reading, this chunk is skipped.
    public func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        lock.withLockIfAvailableUnchecked { pos in
            for i in 0..<frames {
                ring[pos] = (left[i] + right[i]) * 0.5
                pos = (pos + 1) & (Self.size - 1)
            }
        }
    }

    /// Clears the history so bars drop to the floor when audio stops.
    public func reset() {
        lock.withLockUnchecked { pos in
            ring.update(repeating: 0, count: Self.size)
            pos = 0
        }
        shown = []
    }

    /// Level in dBFS (0 = full-scale sine, floor -90) of `bars` log-spaced bands from 20 Hz to 20 kHz.
    /// Rises instantly, falls 1.5 dB per call, like a meter.
    public func levels(bars: Int = 48) -> [Float] {
        var samples = [Float](repeating: 0, count: Self.size)
        lock.withLockUnchecked { pos in // oldest sample first
            samples.withUnsafeMutableBufferPointer { s in
                s.baseAddress!.update(from: ring + pos, count: Self.size - pos)
                (s.baseAddress! + Self.size - pos).update(from: ring, count: pos)
            }
        }
        vDSP.multiply(samples, window, result: &samples)

        let half = Self.size / 2
        let evens = stride(from: 0, to: Self.size, by: 2).map { samples[$0] }
        let odds = stride(from: 1, to: Self.size, by: 2).map { samples[$0] }
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        dft.transform(inputReal: evens, inputImaginary: odds, outputReal: &re, outputImaginary: &im)
        // Real DFT is 2x the textbook one and Hann halves a sine's peak: amplitude = |X| * 2 / n.
        let scale = 2 / Float(Self.size)
        let amp = (0..<half).map { k -> Float in (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale }

        let binHz = sampleRate / Double(Self.size)
        let levels = (0..<bars).map { i -> Float in
            let lo = 20 * pow(1000, Double(i) / Double(bars)), hi = 20 * pow(1000, Double(i + 1) / Double(bars))
            // Nearest bin at each edge, so a tone on a bar boundary still shows.
            var first = max(1, Int((lo / binHz).rounded())), last = min(half - 1, Int((hi / binHz).rounded()))
            if first > last { first = min(half - 1, max(1, Int((sqrt(lo * hi) / binHz).rounded()))); last = first }
            let peak = amp[first...last].max() ?? 0
            return max(Self.floorDB, 20 * log10(max(peak, 1e-9)))
        }

        if shown.count != bars { shown = Array(repeating: Self.floorDB, count: bars) }
        shown = zip(levels, shown).map { max($0, $1 - 1.5) }
        return shown
    }
}
