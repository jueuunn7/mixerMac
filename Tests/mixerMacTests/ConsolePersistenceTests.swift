@testable import MixerAudio
import MixerCore
import Foundation
import Testing
@testable import mixerMac

struct ConsolePersistenceTests {
    @Test func legacySettingsMigrateOnceWithoutOverwritingNewSettings() throws {
        try withDefaults { defaults in
            let domain = "mixerMacTests.legacy.\(UUID().uuidString)"
            let legacy = try #require(UserDefaults(suiteName: domain))
            defer { legacy.removePersistentDomain(forName: domain) }
            legacy.set("old-output", forKey: "output.uid")
            legacy.set(true, forKey: "mixer.running")
            legacy.set(Data([1, 2]), forKey: "channel.example.app")
            legacy.set("unrelated", forKey: "unrelated")
            defaults.set("new-output", forKey: "output.uid")
            ConsolePreferences.migrateLegacySettings(defaults: defaults, legacyDomain: domain)
            #expect(defaults.string(forKey: "output.uid") == "new-output")
            #expect(defaults.bool(forKey: "mixer.running"))
            #expect(defaults.data(forKey: "channel.example.app") == Data([1, 2]))
            #expect(defaults.object(forKey: "unrelated") == nil)
            defaults.set(false, forKey: "mixer.running")
            ConsolePreferences.migrateLegacySettings(defaults: defaults, legacyDomain: domain)
            #expect(!defaults.bool(forKey: "mixer.running"))
        }
    }

    private func withDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let suite = "mixerMacTests.console.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    @Test @MainActor func appSettingsSaveImmediatelyAndSurviveRecreationAndStop() throws {
        try withDefaults { defaults in
            // No processes and no playback: stopping never starts a hardware capture.
            let app = AudioApp(id: "test.channel", name: "Test", icon: nil, processes: [], isPlaying: false)
            let channel = AppAudioChannel(app: app, defaults: defaults)
            channel.settings.gains[4] = -3.5
            channel.settings.trimDB = 2
            channel.settings.volume = 0.42
            channel.isMuted = true
            let muted = AppAudioChannel(app: app, defaults: defaults)
            #expect(muted.isMuted)
            #expect(!muted.isSolo)
            channel.isSolo = true
            channel.stopProcessing()
            #expect(channel.isMuted)
            #expect(channel.isSolo)
            channel.shutdown()
            let reopened = AppAudioChannel(app: app, defaults: defaults)
            #expect(reopened.settings.gains[4] == -3.5)
            #expect(reopened.settings.trimDB == 2)
            #expect(reopened.settings.volume == 0.42)
            #expect(reopened.settings.eqEnabled)
            #expect(reopened.isMuted)
            #expect(reopened.isSolo)
            reopened.isMuted = false
            reopened.isSolo = false
            let cleared = AppAudioChannel(app: app, defaults: defaults)
            #expect(!cleared.isMuted)
            #expect(!cleared.isSolo)
        }
    }

    @Test func oldChannelSettingsDefaultMuteAndSoloWithoutLosingEQ() throws {
        var legacy: [String: Any] = [
            "gains": [Float](repeating: -2, count: 10),
            "volume": 0.65,
            "eqEnabled": true
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let restored = try JSONDecoder().decode(ChannelSettings.self, from: data)
        #expect(!restored.isMuted)
        #expect(!restored.isSolo)
        #expect(restored.trimDB == 0)
        #expect(restored.volume == 0.65)
        #expect(restored.gains == [Float](repeating: -2, count: 10))
        legacy["isMuted"] = true
        let mutedData = try JSONSerialization.data(withJSONObject: legacy)
        let muted = try JSONDecoder().decode(ChannelSettings.self, from: mutedData)
        #expect(muted.isMuted)
        #expect(!muted.isSolo)
    }

    @Test @MainActor func masterEQAndOutputUIDSurviveModelRecreation() throws {
        try withDefaults { defaults in
            let preferences = ConsolePreferences(defaults: defaults)
            let model = MixerConsoleModel(preferences: preferences)
            model.masterEQ.gains[2] = -4
            model.masterEQ.gains[BusEQSettings.frequencies.count - 1] = 3
            model.restoreOutputSelection(devices: [OutputDevice(id: 42, name: "Test", uid: "persistent-output")], defaultOutputID: 42)
            model.selectOutput(42)
            let reopened = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
            #expect(reopened.masterEQ == model.masterEQ)
            #expect(reopened.masterEQ.gains[2] == -4)
            #expect(reopened.masterEQ.gains.last == 3)
            #expect(preferences.outputUID == "persistent-output")
            reopened.restoreOutputSelection(devices: [], defaultOutputID: 0)
            #expect(reopened.outputID == 0)
            reopened.restoreOutputSelection(devices: [
                OutputDevice(id: 5, name: "Default", uid: "other-output"),
                OutputDevice(id: 99, name: "Test", uid: "persistent-output")
            ], defaultOutputID: 5)
            // Core Audio IDs can change across launches; the stable UID wins.
            #expect(reopened.outputID == 99)
        }
    }

    @Test @MainActor func legacyMasterAttenuationIsIgnored() throws {
        try withDefaults { defaults in
            defaults.set(0.12, forKey: "master.volume")
            let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults),
                makeCapture: { _, _ in TestAudioCapture() })
            defer { model.shutdown() }
            let app = AudioApp(id: "test.unity", name: "Test", icon: nil, processes: [], isPlaying: false)
            model.refresh(apps: [app], devices: [], defaultOutputID: 0)
            let channel = try #require(model.channels.first)
            #expect(abs(channel.processor.levelControl.globalGain) < 0.0001)
            channel.settings.volume = 0.5
            #expect(abs(channel.processor.levelControl.globalGain - 20 * log10(Float(0.5))) < 0.0001)
            #expect(channel.processor.masterEQ.bands.count == BusEQSettings.frequencies.count)
        }
    }

    @Test @MainActor func shutdownPreservesRunningIntentWhileExplicitStopClearsIt() throws {
        try withDefaults { defaults in
            let preferences = ConsolePreferences(defaults: defaults)
            preferences.saveMixerRunning(true)
            let model = MixerConsoleModel(preferences: preferences,
                processChannel: { channel, _ in channel.isProcessing = true },
                discoverOwnProcesses: { [99] }, makeCapture: { _, _ in TestAudioCapture() })
            let app = AudioApp(id: "shutdown.test", name: "Test", icon: nil, processes: [11], isPlaying: false)
            model.refresh(apps: [app], devices: [OutputDevice(id: 42, name: "Test", uid: "test-output")], defaultOutputID: 42)
            #expect(model.isMixing)
            model.shutdown()
            #expect(!model.isMixing)
            #expect(preferences.mixerWasRunning)
            let reopened = MixerConsoleModel(preferences: preferences)
            reopened.stopMixing()
            #expect(!preferences.mixerWasRunning)
            reopened.shutdown()
            #expect(!preferences.mixerWasRunning)
            #expect(!MixerRunRestoration(preferences: preferences).isPending)
        }
    }

    @Test @MainActor func existingSettingsDoNotImplyFirstLaunchShouldStartMixing() throws {
        try withDefaults { defaults in
            defaults.set("existing-output", forKey: "output.uid")
            defaults.set(0.3, forKey: "master.volume")
            defaults.set(try JSONEncoder().encode(BusEQSettings()), forKey: "master.eq")
            var savedChannel = ChannelSettings()
            savedChannel.isMuted = true
            savedChannel.isSolo = true
            defaults.set(try JSONEncoder().encode(savedChannel), forKey: "channel.existing.app")
            let preferences = ConsolePreferences(defaults: defaults)
            let model = MixerConsoleModel(preferences: preferences)
            #expect(!model.isMixing)
            #expect(!preferences.mixerWasRunning)
            #expect(!MixerRunRestoration(preferences: preferences).isPending)
            model.shutdown()
            #expect(defaults.object(forKey: "mixer.running") == nil)
        }
    }

    @Test func startupWaitsForBothOutputAndAppsAndConsumesOnlyOneAttempt() throws {
        try withDefaults { defaults in
            let preferences = ConsolePreferences(defaults: defaults)
            #expect(!MixerRunRestoration(preferences: preferences).isPending)
            preferences.saveMixerRunning(true)
            var restoration = MixerRunRestoration(preferences: preferences)
            let attemptWithoutDevicesOrApps = restoration.takeStartupAttempt(hasOutput: false, hasApps: false)
            #expect(!attemptWithoutDevicesOrApps)
            let attemptWithoutApps = restoration.takeStartupAttempt(hasOutput: true, hasApps: false)
            #expect(!attemptWithoutApps)
            let attemptWithoutOutput = restoration.takeStartupAttempt(hasOutput: false, hasApps: true)
            #expect(!attemptWithoutOutput)
            #expect(restoration.isPending)
            let readyAttempt = restoration.takeStartupAttempt(hasOutput: true, hasApps: true)
            #expect(readyAttempt)
            // A thrown start leaves this consumed, preventing a refresh retry loop.
            let repeatAttempt = restoration.takeStartupAttempt(hasOutput: true, hasApps: true)
            #expect(!repeatAttempt)
            #expect(preferences.mixerWasRunning)
            restoration.shutdown()
            let attemptAfterShutdown = restoration.takeStartupAttempt(hasOutput: true, hasApps: true)
            #expect(!attemptAfterShutdown)
            // The user's intent survives failure/teardown for the next launch.
            #expect(MixerRunRestoration(preferences: preferences).isPending)
        }
    }

    @Test func explicitStopCancelsPendingStartupAndOutputLossCanWaitAgain() throws {
        try withDefaults { defaults in
            let preferences = ConsolePreferences(defaults: defaults)
            var restoration = MixerRunRestoration(preferences: preferences)
            restoration.explicitStart()
            #expect(preferences.mixerWasRunning)
            restoration.waitForAvailability()
            #expect(restoration.isPending)
            restoration.explicitStop()
            #expect(!preferences.mixerWasRunning)
            let attemptAfterExplicitStop = restoration.takeStartupAttempt(hasOutput: true, hasApps: true)
            #expect(!attemptAfterExplicitStop)
            restoration.waitForAvailability()
            #expect(!restoration.isPending)
        }
    }

    @Test @MainActor func meterQuantizationNeverRoundsSubUnityUpToFullScale() {
        let metrics = ChannelAudioMetrics()
        metrics.setLevel(0.9999)
        let expected: Float = 119 / 120
        #expect(metrics.level == expected)
        #expect(metrics.heldPeak == expected)
        metrics.setLevel(1)
        #expect(metrics.level == 1)
        #expect(metrics.heldPeak == 1)
    }

    @Test func peakRemainsHeldForOneAndAHalfSeconds() {
        var hold = MeterPeakHold()
        hold.update(1, now: 10)
        hold.update(0, now: 11.49)
        #expect(hold.level == 1)
        hold.update(0, now: 11.6)
        #expect(hold.level < 1)
        #expect(abs(hold.level - 0.965) < 0.0001)
    }
}
