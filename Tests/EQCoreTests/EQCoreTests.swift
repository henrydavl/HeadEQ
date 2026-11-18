import Foundation
import Testing
@testable import EQCore

struct BiquadTests {
    @Test(arguments: [(1000.0, 12.0, 1.0), (60.0, -6.0, 0.7), (8000.0, 4.5, 4.0)])
    func peakingHitsGainAtCenter(freq: Double, gain: Double, q: Double) {
        let bq = Biquad.peaking(freq: freq, gainDB: gain, q: q, sampleRate: 48_000)
        #expect(abs(bq.magnitudeDB(at: freq, sampleRate: 48_000) - gain) < 0.01)
        #expect(abs(bq.magnitudeDB(at: freq / 50, sampleRate: 48_000)) < 0.5)
    }

    /// Graph 300 × 200 pt, 3 decades wide (100 pt per decade), ±18 dB tall (200 pt = 36 dB).
    @Test func dragMovesByOffset() {
        let band = Band(id: 0, freq: 1234, gainDB: 2.3)
        func drag(_ dx: Double, _ dy: Double, _ b: Band = band) -> Band {
            b.dragged(dx: dx, dy: dy, width: 300, height: 200, dbRange: 18)
        }
        #expect(drag(0, 0) == band)                          // a click changes nothing
        #expect(abs(drag(0, -50).gainDB - (2.3 + 9)) < 1e-9) // up raises gain
        #expect(abs(drag(0, 50).gainDB - (2.3 - 9)) < 1e-9)  // down lowers it
        #expect(drag(100, 0, Band(id: 0, freq: 100)).freq == 1000) // right one decade = ×10
        #expect(drag(-100, 0, Band(id: 0, freq: 1000)).freq == 100)
        #expect(drag(1000, -1000) .freq == Band.freqRange.upperBound)
        #expect(drag(1000, -1000).gainDB == Band.gainRange.upperBound)
        #expect(drag(-1000, 1000).freq == Band.freqRange.lowerBound)
    }

    @Test func flatSettingsAreUnity() {
        let s = EQSettings()
        for f in [20.0, 440, 5000, 19000] { #expect(abs(s.magnitudeDB(at: f)) < 1e-9) }
    }

    @Test func settingsRoundTripJSON() throws {
        var s = EQSettings(preampDB: -3)
        s.bands[4].gainDB = 5
        s.bands[4].q = 2.5
        let back = try JSONDecoder().decode(EQSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

struct ProcessorTests {
    /// RMS gain in dB of a sine at `freq` pushed through the processor (steady state).
    func measuredGain(_ settings: EQSettings, freq: Double, sampleRate: Double = 48_000) -> Double {
        let p = EQProcessor(sampleRate: sampleRate, settings: settings)
        let n = 48_000
        let sine = (0..<n).map { Float(sin(2 * Double.pi * freq * Double($0) / sampleRate)) }
        var l = sine, r = sine
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                p.process(left: lb.baseAddress!, right: rb.baseAddress!, frames: n)
            }
        }
        func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count)) }
        let tail = n / 2..<n
        #expect(abs(rms(l[tail]) - rms(r[tail])) < 1e-6) // both channels filtered alike
        return 20 * log10(rms(l[tail]) / rms(sine[tail]))
    }

    @Test func boostsOnlyTheTunedBand() {
        var s = EQSettings()
        s.bands[5].gainDB = 12  // 1 kHz
        s.bands[1].gainDB = -6  // 64 Hz
        s.bands[1].q = 2
        #expect(abs(measuredGain(s, freq: 1000) - s.magnitudeDB(at: 1000)) < 0.1)
        #expect(abs(measuredGain(s, freq: 64) - s.magnitudeDB(at: 64)) < 0.1)
        #expect(abs(measuredGain(s, freq: 10_000) - s.magnitudeDB(at: 10_000)) < 0.1)
    }

    @Test func preampAndBypassedBands() {
        var s = EQSettings(preampDB: -6)
        s.bands[5].gainDB = 12
        s.bands[5].enabled = false
        #expect(abs(measuredGain(s, freq: 1000) + 6) < 0.05)
    }

    @Test func updateTakesEffect() {
        let p = EQProcessor(sampleRate: 48_000, settings: EQSettings())
        var s = EQSettings()
        s.bands[5].gainDB = 9
        p.update(s)
        var l = (0..<48_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        var r = l
        p.process(left: &l, right: &r, frames: l.count)
        let peak = l[24_000...].map(abs).max()!
        #expect(abs(20 * log10(Double(peak)) - 9) < 0.1)
    }
}

struct ProfileTests {
    @Test func addDeleteRestore() throws {
        var d = DeviceProfiles()
        d.selected.eq.bands[3].gainDB = 4
        let first = d.selectedID

        d.addProfile()
        #expect(d.profiles.map(\.name) == ["Default", "Profile 2"])
        #expect(d.selected.eq == EQSettings()) // new profiles start flat
        d.selected.eq.preampDB = -2

        d.selectedID = first
        #expect(d.selected.eq.bands[3].gainDB == 4) // switching keeps each profile's EQ
        d.restoreDefault()
        #expect(d.selected.eq == EQSettings())
        #expect(d.profiles[1].eq.preampDB == -2)

        d.deleteSelected()
        #expect(d.profiles.map(\.name) == ["Profile 2"])
        d.deleteSelected() // last one stays
        #expect(d.profiles.count == 1)

        d.addProfile()
        #expect(d.profiles.map(\.name) == ["Profile 2", "Profile 3"])
    }

    @Test func newNamesAreUnique() {
        var d = DeviceProfiles()
        d.addProfile(); d.addProfile()          // Default, Profile 2, Profile 3
        d.selectedID = d.profiles[1].id
        d.deleteSelected()                      // Default, Profile 3
        d.addProfile()
        #expect(Set(d.profiles.map(\.name)).count == d.profiles.count)
    }

    @Test func invalidSavedDataRejected() throws {
        var d = DeviceProfiles()
        #expect(d.isValid)
        d.profiles[0].eq.bands.removeLast()
        #expect(!d.isValid)
        let back = try JSONDecoder().decode(DeviceProfiles.self, from: JSONEncoder().encode(DeviceProfiles()))
        #expect(back.isValid)
    }
}

struct SpectrumTests {
    func feed(_ a: SpectrumAnalyzer, freq: Double, amplitude: Float = 1) {
        let n = SpectrumAnalyzer.size
        let s = (0..<n).map { amplitude * Float(sin(2 * Double.pi * freq * Double($0) / a.sampleRate)) }
        a.push(left: s, right: s, frames: n)
    }

    /// Index of the bar (of 48, log 20 Hz–20 kHz) that contains `freq`.
    func bar(_ freq: Double) -> Int { Int(48 * log10(freq / 20) / 3) }

    @Test func fullScaleSineReadsZeroDBInItsBar() {
        let a = SpectrumAnalyzer()
        feed(a, freq: 1000)
        let l = a.levels()
        #expect(abs(l[bar(1000)]) < 2)          // full-scale sine ≈ 0 dBFS
        #expect(l[bar(100)] < -60)              // far away stays low
        #expect(l[bar(10_000)] < -60)
    }

    @Test func quieterSineReadsLower() {
        let a = SpectrumAnalyzer()
        feed(a, freq: 200, amplitude: 0.1)      // -20 dBFS
        #expect(abs(a.levels()[bar(200)] + 20) < 2)
    }

    @Test func resetDropsToFloor() {
        let a = SpectrumAnalyzer()
        feed(a, freq: 1000)
        _ = a.levels()
        a.reset()
        #expect(a.levels().allSatisfy { $0 == SpectrumAnalyzer.floorDB })
    }
}
