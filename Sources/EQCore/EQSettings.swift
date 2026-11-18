import Foundation

public struct Band: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var freq: Double
    public var gainDB: Double
    public var q: Double
    public var enabled: Bool

    public static let freqRange = 20.0...20_000.0
    public static let gainRange = -15.0...15.0
    public static let qRange = 0.1...10.0

    public init(id: Int, freq: Double, gainDB: Double = 0, q: Double = 1, enabled: Bool = true) {
        self.id = id
        self.freq = freq
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
    }

    /// Biquad for this band, identity when disabled or flat.
    public func biquad(sampleRate: Double) -> Biquad {
        guard enabled, gainDB != 0 else { return .identity }
        return .peaking(freq: freq, gainDB: gainDB, q: q, sampleRate: sampleRate)
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

    /// Combined response of all bands plus preamp, in dB.
    public func magnitudeDB(at freq: Double, sampleRate: Double = 48_000) -> Double {
        bands.reduce(preampDB) { $0 + $1.biquad(sampleRate: sampleRate).magnitudeDB(at: freq, sampleRate: sampleRate) }
    }
}
