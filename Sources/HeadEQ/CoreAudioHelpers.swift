import CoreAudio
import Foundation

struct CAError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

func check(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw CAError(step: step, status: status) }
}

/// Thin typed wrappers over AudioObjectGetPropertyData.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Read property \(selector)")
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Read string \(selector)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "Find own audio process")
        guard object != kAudioObjectUnknown else { throw CAError(step: "Find own audio process", status: -1) }
        return object
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Marks only input streams from `firstUsed` on as used by `proc`, so the HAL
    /// leaves the headphones' own mic off (on AirPods an open mic drops playback to call quality).
    static func useInputStreams(of device: AudioObjectID, proc: AudioDeviceIOProcID, from firstUsed: Int) throws {
        let count = streamCount(device, scope: kAudioObjectPropertyScopeInput)
        guard firstUsed > 0, count > firstUsed else { return }
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = flagsOffset + MemoryLayout<UInt32>.stride * count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for i in 0..<count { flags[i] = i >= firstUsed ? 1 : 0 }
        var addr = address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(size), raw), "Set stream usage")
    }
}
