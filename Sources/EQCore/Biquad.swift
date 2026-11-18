import Foundation

/// Normalized biquad (a0 = 1), in vDSP's order: y = b0x + b1x1 + b2x2 - a1y1 - a2y2.
public struct Biquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// RBJ Audio EQ Cookbook peaking filter.
    public static func peaking(freq: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let f = min(freq, sampleRate * 0.49) // above Nyquist the filter is unstable
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.01))
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0,
            b1: -2 * cosw / a0,
            b2: (1 - alpha * a) / a0,
            a1: -2 * cosw / a0,
            a2: (1 - alpha / a) / a0
        )
    }

    public var coefficients: [Double] { [b0, b1, b2, a1, a2] }

    /// |H(e^jw)| in dB.
    public func magnitudeDB(at freq: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2)
        let denRe = 1 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2)
        let mag2 = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
        return 10 * log10(mag2)
    }
}
