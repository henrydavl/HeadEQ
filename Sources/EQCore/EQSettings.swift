import Foundation

public struct Band: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var freq: Double
    public var gainDB: Double
    public var q: Double
    public var enabled: Bool
    /// Dynamic band: the gain only applies while this band's level is above `thresholdDB`.
    public var dynamic: Bool
    public var thresholdDB: Double

    public static let freqRange = 20.0...20_000.0
    public static let gainRange = -15.0...15.0
    public static let qRange = 0.1...10.0
    public static let thresholdRange = -60.0...0.0
    /// A dynamic band reaches its full gain this many dB above the threshold.
    public static let dynamicSpanDB = 10.0

    public init(id: Int, freq: Double, gainDB: Double = 0, q: Double = 1, enabled: Bool = true,
                dynamic: Bool = false, thresholdDB: Double = -30) {
        self.id = id
        self.freq = freq
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
        self.dynamic = dynamic
        self.thresholdDB = thresholdDB
    }

    // Profiles saved before dynamic EQ existed have no dynamic keys; they must still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(Int.self, forKey: .id),
                  freq: try c.decode(Double.self, forKey: .freq),
                  gainDB: try c.decode(Double.self, forKey: .gainDB),
                  q: try c.decode(Double.self, forKey: .q),
                  enabled: try c.decode(Bool.self, forKey: .enabled),
                  dynamic: try c.decodeIfPresent(Bool.self, forKey: .dynamic) ?? false,
                  thresholdDB: try c.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? -30)
    }

    /// Gain a dynamic band applies for a band level of `levelDB`: none below the threshold,
    /// growing to the full gain `dynamicSpanDB` above it.
    public func dynamicGain(levelDB: Double) -> Double {
        gainDB * min(max((levelDB - thresholdDB) / Self.dynamicSpanDB, 0), 1)
    }

    /// Biquad for this band, identity when disabled or flat.
    public func biquad(sampleRate: Double) -> Biquad {
        guard enabled, gainDB != 0 else { return .identity }
        return .peaking(freq: freq, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }

    /// This band moved by a pointer drag of (dx, dy) on a graph `width` wide spanning 20 Hz–20 kHz
    /// (3 decades, log) and `height` tall spanning ±`dbRange` dB. Screen y grows downward, so up raises gain.
    /// Moves by offset, so a click without movement changes nothing.
    public func dragged(dx: Double, dy: Double, width: Double, height: Double, dbRange: Double) -> Band {
        guard dx != 0 || dy != 0 else { return self }
        var band = self
        let f = freq * pow(10, 3 * dx / width)
        let g = gainDB - 2 * dbRange * dy / height
        band.freq = min(max(f < 1000 ? f.rounded() : (f / 10).rounded() * 10, Self.freqRange.lowerBound), Self.freqRange.upperBound)
        band.gainDB = min(max((g * 10).rounded() / 10, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        return band
    }
}

public struct EQSettings: Codable, Equatable, Sendable {
    public var preampDB: Double
    public var bands: [Band]

    public static let preampRange = -24.0...6.0
    public static let defaultFreqs: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public init(preampDB: Double = 0, bands: [Band]? = nil) {
        self.preampDB = preampDB
        self.bands = bands ?? Self.defaultFreqs.enumerated().map { Band(id: $0.offset, freq: $0.element) }
    }

    /// Puts band `index` back to its default frequency, 0 dB, Q 1, on.
    public mutating func resetBand(_ index: Int) {
        bands[index] = Band(id: index, freq: Self.defaultFreqs[index])
    }

    /// Combined response of all bands plus preamp, in dB.
    public func magnitudeDB(at freq: Double, sampleRate: Double = 48_000) -> Double {
        bands.reduce(preampDB) { $0 + $1.biquad(sampleRate: sampleRate).magnitudeDB(at: freq, sampleRate: sampleRate) }
    }
}
