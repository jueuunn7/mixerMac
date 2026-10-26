import Foundation

struct ConsolePreferences {
    /// Copy known settings once, preserving any values already saved by mixerMac.
    static func migrateLegacySettings(defaults: UserDefaults = .standard,
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

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var outputUID: String? { defaults.string(forKey: "output.uid") }
    var mixerWasRunning: Bool { defaults.bool(forKey: "mixer.running") }
    func saveOutputUID(_ uid: String) { defaults.set(uid, forKey: "output.uid") }
    func saveMixerRunning(_ running: Bool) { defaults.set(running, forKey: "mixer.running") }
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
