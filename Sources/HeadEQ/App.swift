import CoreAudio
import EQCore
import SwiftUI

@main
struct HeadEQApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("HeadEQ", systemImage: model.enabled ? "slider.vertical.3" : "speaker.wave.2") {
            EQView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns which output device is active and which of its profiles plays.
@MainActor
final class AppModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            sync()
        }
    }
    /// Profiles per output device UID.
    @Published var library: [String: DeviceProfiles] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(library), forKey: "library")
            engine.update(eq)
        }
    }
    @Published private(set) var deviceUID = ""
    @Published private(set) var deviceName = "No output"
    @Published private(set) var status = ""

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private let engine = AudioEngine()

    var profiles: DeviceProfiles {
        get { library[deviceUID] ?? DeviceProfiles() }
        set { library[deviceUID] = newValue }
    }

    var eq: EQSettings {
        get { profiles.selected.eq }
        set { profiles.selected.eq = newValue }
    }

    init() {
        let saved = UserDefaults.standard.data(forKey: "library")
            .flatMap { try? JSONDecoder().decode([String: DeviceProfiles].self, from: $0) } ?? [:]
        library = saved.filter { $0.value.isValid }
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        engine.onStatus = { [weak self] in self?.status = $0 }

        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDevice() }
        }
        refreshDevice()
    }

    /// Follows the system output (plugging in headphones switches to their profiles).
    private func refreshDevice() {
        guard let id = try? CA.defaultOutputDevice(), id != kAudioObjectUnknown,
              let uid = try? CA.string(id, kAudioDevicePropertyDeviceUID) else {
            deviceID = AudioObjectID(kAudioObjectUnknown)
            deviceName = "No output"
            engine.stop()
            return
        }
        deviceID = id
        deviceUID = uid
        deviceName = (try? CA.string(id, kAudioObjectPropertyName)) ?? "Output"
        if library[uid] == nil { library[uid] = DeviceProfiles() }
        sync()
    }

    private func sync() {
        if enabled, deviceID != kAudioObjectUnknown {
            engine.run(on: deviceID, settings: eq)
        } else {
            engine.stop()
            status = "Bypassed"
        }
    }
}
