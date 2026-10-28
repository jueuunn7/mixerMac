import Combine
import Foundation
import MixerCore
import MixerStandardNodes
@testable import MixerAudio
import Testing
@testable import mixerMac

struct MixerCoreIntegrationTests {
    @MainActor
    private func withMixer(_ test: (MixerConsoleModel, AppAudioChannel, AppAudioChannel, UserDefaults) throws -> Void) throws {
        let suite = "mixerMac.CoreIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults),
            makeCapture: { _, _ in TestAudioCapture() })
        let apps = [
            AudioApp(id: "first", name: "First", icon: nil, processes: [], isPlaying: false),
            AudioApp(id: "second", name: "Second", icon: nil, processes: [], isPlaying: false)
        ]
        model.refresh(apps: apps, devices: [], defaultOutputID: 0)
        let first = try #require(model.channels.first { $0.id == "first" })
        let second = try #require(model.channels.first { $0.id == "second" })
        defer { model.shutdown() }
        try test(model, first, second, defaults)
    }

    @Test @MainActor func settingsReachPersistenceAndPlaybackWithoutAViewOrManualApply() throws {
        try withMixer { model, first, second, defaults in
            #expect(model.core.channels[0] === first.core)
            first.settings.volume = 0.5
            let measuredPeak1 = try renderedConsolePeak(settings: first.settings)
            #expect(abs(measuredPeak1 - 0.05) < 0.001)
            let measuredPeak2 = try renderedConsolePeak(settings: second.settings)
            #expect(abs(measuredPeak2 - 0.1) < 0.001)
            let saved = try #require(defaults.data(forKey: "channel.first"))
            #expect(try JSONDecoder().decode(ChannelSettings.self, from: saved).volume == 0.5)
        }
    }

    @Test @MainActor func knobAndDetailBindingsShareThePersistedPlaybackParameter() throws {
        try withMixer { _, first, _, defaults in
            let knob = first.core.equalizer.bands[5].gain.binding
            knob.wrappedValue = 3.5
            #expect(first.settings.gains[5] == 3.5)
            var detail = first.settings
            detail.gains[5] = -4.1
            first.settings = detail
            #expect(knob.wrappedValue == -4.1)
            let measuredPeak3 = try renderedConsolePeak(settings: first.settings)
            #expect(abs(20 * log10(measuredPeak3 / 0.1) + 4.1) < 0.2)
            let saved = try #require(defaults.data(forKey: "channel.first"))
            #expect(try JSONDecoder().decode(ChannelSettings.self, from: saved).gains[5] == -4.1)
        }
    }

    @Test @MainActor func masterParameterChangesReachEveryChannelAndSurviveRecreation() throws {
        try withMixer { model, first, second, defaults in
            model.core.master.equalizer.gain.setValue(-7.5)
            model.core.master.width.setValue(1.35)
            let measuredPeak4 = try renderedConsolePeak(settings: first.settings, master: model.masterEQ)
            #expect(abs(20 * log10(measuredPeak4 / 0.1) + 7.5) < 0.05)
            let measuredPeak5 = try renderedConsolePeak(settings: second.settings, master: model.masterEQ)
            #expect(abs(20 * log10(measuredPeak5 / 0.1) + 7.5) < 0.05)
            let reopened = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
            #expect(reopened.core.master.equalizer.gain.value == -7.5)
            #expect(reopened.core.master.width.value == 1.35)
        }
    }

    @Test @MainActor func bulkDetailEditsNotifyOnceAfterTheCompleteSettingsAreApplied() throws {
        try withMixer { model, first, _, _ in
            var observed: [ChannelSettings] = []
            let subscription = model.core.changes.sink { change in
                if change == .channel("first") { observed.append(first.settings) }
            }
            var settings = first.settings
            settings.gains[3] = -2.4
            settings.frequencies[3] = 275
            settings.bandwidths[3] = 0.5
            first.settings = settings
            #expect(observed == [settings])
            let measuredPeak6 = try renderedConsolePeak(settings: first.settings, frequency: 275, frames: 48000)
            #expect(abs(20 * log10(measuredPeak6 / 0.1) + 2.4) < 0.05)
            withExtendedLifetime(subscription) {}
        }
    }
}
