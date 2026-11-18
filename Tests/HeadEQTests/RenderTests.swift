import CoreAudio
import EQCore
import Testing
@testable import HeadEQ

/// `AudioEngine.render` decides what reaches the headphones; a wrong index means swapped or silent audio.
struct RenderTests {
    let frames = 8
    let left: [Float] = (1...8).map { Float($0) / 10 }
    let right: [Float] = (1...8).map { -Float($0) / 10 }

    /// Buffer list whose buffers hold `channels[i]` interleaved channels, filled from `fill` (or zeros).
    func bufferList(_ channels: [Int], fill: [[Float]]? = nil) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (i, ch) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * ch)
            data.initialize(repeating: 0, count: frames * ch)
            if let samples = fill?[i] { data.update(from: samples, count: samples.count) }
            list[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(frames * ch * 4), mData: data)
        }
        return list
    }

    func samples(_ list: UnsafeMutableAudioBufferListPointer, buffer: Int) -> [Float] {
        let b = list[buffer]
        return Array(UnsafeBufferPointer(start: b.mData!.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4))
    }

    /// Runs render with a headset mic (1 ch) as input stream 0 and the stereo tap as stream 1.
    func render(into output: UnsafeMutableAudioBufferListPointer) {
        let interleaved = zip(left, right).flatMap { [$0, $1] }
        let input = bufferList([1, 2], fill: [Array(repeating: 9, count: frames), interleaved])
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        AudioEngine.render(input: input.unsafePointer, output: output.unsafeMutablePointer, tapStream: 1,
                           left: l, right: r, processor: EQProcessor(sampleRate: 48_000, settings: EQSettings()),
                           analyzer: SpectrumAnalyzer())
    }

    @Test func interleavedStereoOutput() {
        let out = bufferList([2])
        render(into: out)
        #expect(samples(out, buffer: 0) == zip(left, right).flatMap { [$0, $1] })
    }

    @Test func oneStreamPerChannel() {
        let out = bufferList([1, 1])
        render(into: out)
        #expect(samples(out, buffer: 0) == left)
        #expect(samples(out, buffer: 1) == right)
    }

    @Test func extraChannelsAreSilent() {
        let out = bufferList([4])
        render(into: out)
        let s = samples(out, buffer: 0)
        #expect(stride(from: 0, to: s.count, by: 4).map { s[$0] } == left)
        #expect(stride(from: 1, to: s.count, by: 4).map { s[$0] } == right)
        #expect(s.enumerated().filter { $0.offset % 4 >= 2 }.allSatisfy { $0.element == 0 })
    }
}
