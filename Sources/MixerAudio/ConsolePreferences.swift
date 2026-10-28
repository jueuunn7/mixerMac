import Foundation

public struct ConsolePreferences {
    /// Copy known settings once, preserving any values already saved by mixerMac.
    public static func migrateLegacySettings(defaults: UserDefaults = .standard,
                                      legacyDomain: String = "local.mixroom.app") {
        let marker = "settings.migratedLegacyDomain"
        guard !defaults.bool(forKey: marker) else { return }
        let saved = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        for (key, value) in saved where key.hasPrefix("channel.") ||
            ["master.eq", "output.uid", "mixer.running"].contains(key) {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }

    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var channelOrder: [String] { defaults.stringArray(forKey: "channel.order") ?? [] }
    public func saveChannelOrder(_ ids: [String]) { defaults.set(ids, forKey: "channel.order") }
    public var outputUID: String? { defaults.string(forKey: "output.uid") }
    public var mixerWasRunning: Bool { defaults.bool(forKey: "mixer.running") }
    public func saveOutputUID(_ uid: String) { defaults.set(uid, forKey: "output.uid") }
    public func saveMixerRunning(_ running: Bool) { defaults.set(running, forKey: "mixer.running") }
}

/// Keeps the user's intent independent of engine teardown and startup failures.
struct MixerRunRestoration {
    private let preferences: ConsolePreferences
    private(set) var isPending: Bool

    init(preferences: ConsolePreferences) {
        self.preferences = preferences
        isPending = preferences.mixerWasRunning
    }

    mutating func takeStartupAttempt(hasOutput: Bool, hasApps: Bool) -> Bool {
        guard isPending, hasOutput, hasApps else { return false }
        // Consume before starting: a failed attempt must not retry on every refresh.
        isPending = false
        return true
    }

    mutating func explicitStart() {
        isPending = false
        preferences.saveMixerRunning(true)
    }

    mutating func explicitStop() {
        isPending = false
        preferences.saveMixerRunning(false)
    }

    mutating func waitForAvailability() { isPending = preferences.mixerWasRunning }
    mutating func shutdown() { isPending = false }
}
