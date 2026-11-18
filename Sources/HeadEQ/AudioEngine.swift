import CoreAudio
import EQCore
import Foundation

/// Taps all system audio (muting the original), runs it through the EQ and plays it
/// on the given output device. Main thread only, except the render block.
final class AudioEngine {
    var onStatus: ((String) -> Void)?

    private var settings = EQSettings()
    private var processor: EQProcessor?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var rateListener: AudioObjectPropertyListenerBlock?

    private static let maxFrames = 16_384
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)

    /// (Re)starts EQ on `device`.
    func run(on device: AudioObjectID, settings: EQSettings) {
        stop()
        self.settings = settings
        outputID = device
        start()
    }

    /// Changes the EQ live; no-op while stopped.
    func update(_ settings: EQSettings) {
        self.settings = settings
        processor?.update(settings)
    }

    private func start() {
        do {
            let outputUID = try CA.string(outputID, kAudioDevicePropertyDeviceUID)

            // Exclude ourselves, or our own output would be tapped again (feedback loop).
            let me = try CA.processObject(pid: getpid())
            let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
            tap.uuid = UUID()
            tap.name = "HeadEQ"
            tap.isPrivate = true
            tap.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(tap, &tapID), "Create process tap")

            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "HeadEQ",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "Create aggregate device")

            let rate = try CA.get(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
            let processor = EQProcessor(sampleRate: rate, settings: settings)
            self.processor = processor

            // Aggregate inputs are the output device's own input streams (e.g. a headset mic), then the tap.
            let tapStream = CA.streamCount(outputID, scope: kAudioObjectPropertyScopeInput)
            let (left, right) = (left, right)
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
                Self.render(input: input, output: output, tapStream: tapStream, left: left, right: right, processor: processor)
            }, "Create IO proc")
            try CA.useInputStreams(of: aggregateID, proc: procID!, from: tapStream)
            try check(AudioDeviceStart(aggregateID, procID), "Start audio")

            watchSampleRate(of: outputID)
            onStatus?(String(format: "%g kHz", rate / 1000))
        } catch {
            stop()
            onStatus?("Error: \(error)")
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        if let rateListener {
            var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(outputID, &addr, .main, rateListener)
        }
        rateListener = nil
        processor = nil
    }

    private func watchSampleRate(of device: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            run(on: outputID, settings: settings)
        }
        var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListenerBlock(device, &addr, .main, listener) == noErr { rateListener = listener }
    }

    /// Audio thread. Tap (stereo, interleaved or not) -> L/R scratch -> EQ -> every output stream.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               tapStream: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                               processor: EQProcessor) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        var frames = 0
        if tapStream < inputs.count, let data = inputs[tapStream].mData?.assumingMemoryBound(to: Float.self) {
            let channels = Int(max(inputs[tapStream].mNumberChannels, 1))
            frames = min(Int(inputs[tapStream].mDataByteSize) / (4 * channels), maxFrames)
            for i in 0..<frames {
                left[i] = data[i * channels]
                right[i] = channels > 1 ? data[i * channels + 1] : data[i * channels]
            }
            processor.process(left: left, right: right, frames: frames)
        }

        var channel = 0 // device-wide channel index: 0 = L, 1 = R, rest silent
        for buffer in outputs {
            let channels = Int(max(buffer.mNumberChannels, 1))
            defer { channel += channels }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let capacity = Int(buffer.mDataByteSize) / (4 * channels)
            for c in 0..<channels {
                let source: UnsafeMutablePointer<Float>? = channel + c == 0 ? left : channel + c == 1 ? right : nil
                for i in 0..<capacity {
                    data[i * channels + c] = (source != nil && i < frames) ? source![i] : 0
                }
            }
        }
    }
}
