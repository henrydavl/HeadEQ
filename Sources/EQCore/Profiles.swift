import Foundation

public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var eq: EQSettings

    public init(id: UUID = UUID(), name: String, eq: EQSettings = EQSettings()) {
        self.id = id
        self.name = name
        self.eq = eq
    }
}

/// The profiles saved for one output device (keyed by its Core Audio UID); always at least one.
public struct DeviceProfiles: Codable, Equatable, Sendable {
    public var profiles: [Profile]
    public var selectedID: UUID

    public init() {
        let first = Profile(name: "Default")
        profiles = [first]
        selectedID = first.id
    }

    private var selectedIndex: Int { profiles.firstIndex { $0.id == selectedID } ?? 0 }

    public var selected: Profile {
        get { profiles[selectedIndex] }
        set { profiles[selectedIndex] = newValue }
    }

    /// Adds a flat profile with a free "Profile N" name and selects it.
    public mutating func addProfile() {
        var n = profiles.count + 1
        while profiles.contains(where: { $0.name == "Profile \(n)" }) { n += 1 }
        let new = Profile(name: "Profile \(n)")
        profiles.append(new)
        selectedID = new.id
    }

    /// Deletes the selected profile unless it is the last one; selects its neighbour.
    public mutating func deleteSelected() {
        guard profiles.count > 1 else { return }
        let i = selectedIndex
        profiles.remove(at: i)
        selectedID = profiles[max(i - 1, 0)].id
    }

    public mutating func restoreDefault() { selected.eq = EQSettings() }

    /// Rejects saved data the app can't run (empty list, wrong band count).
    public var isValid: Bool {
        !profiles.isEmpty && profiles.allSatisfy { $0.eq.bands.count == EQSettings.defaultFreqs.count }
    }
}
