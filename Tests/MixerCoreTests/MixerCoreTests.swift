import Combine
import Foundation
import MixerCore
import Testing

struct MixerCoreTests {
    @Test @MainActor func parametersClampResetAndNotifyOnlyAfterAChange() {
        let parameter = Parameter(value: 0, range: -24...24, defaultValue: 0, unit: .decibels)
        var observed: [Float] = []
        let subscription = parameter.changes.sink { observed.append(parameter.value) }
        parameter.setValue(40)
        parameter.setValue(25)
        parameter.setValue(-40)
        parameter.reset()
        parameter.setValue(.nan)
        #expect(observed == [24, -24, 0])
        #expect(parameter.value == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func twoControlsShareOneParameterAndChannelsStayIndependent() {
        let first = Channel(id: "first")
        let second = Channel(id: "second")
        let knob = first.equalizer.bands[5].gain
        let numberEditor = first.equalizer.bands[5].gain
        #expect(knob === numberEditor)
        knob.setValue(3.7)
        #expect(numberEditor.value == 3.7)
        numberEditor.setValue(-4)
        #expect(knob.value == -4)
        #expect(first.settings.gains[5] == -4)
        #expect(second.settings.gains[5] == 0)
    }

    @Test @MainActor func replacingSettingsPreservesParametersAndPublishesOneCompleteSnapshot() {
        let channel = Channel(id: "test")
        let parameter = channel.equalizer.bands[5].gain
        var observed: [ChannelSettings] = []
        let subscription = channel.changes.sink { observed.append(channel.settings) }
        var settings = ChannelSettings()
        settings.gains[5] = 7.3
        settings.frequencies[5] = 1234.5
        settings.bandwidths[5] = 0.35
        settings.trimDB = 2
        settings.volume = 0.42
        settings.pan = -0.65
        settings.isMuted = true
        channel.updateSettings(settings)
        channel.updateSettings(settings)
        #expect(channel.equalizer.bands[5].gain === parameter)
        #expect(observed == [settings])
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func mixerOwnsMuteSoloAndChannelMembership() {
        let first = Channel(id: "first")
        let second = Channel(id: "second")
        let mixer = Mixer(channels: [first])
        mixer.addChannel(second)
        #expect(mixer.audibleChannelIDs == Set(["first", "second"]))
        first.setSolo(true)
        #expect(mixer.audibleChannelIDs == Set(["first"]))
        second.setSolo(true)
        first.setMuted(true)
        #expect(mixer.audibleChannelIDs == Set(["second"]))
        mixer.removeChannel(id: "second")
        #expect(mixer.audibleChannelIDs.isEmpty)
        first.setSolo(false)
        first.setMuted(false)
        #expect(mixer.audibleChannelIDs == Set(["first"]))
    }

    @Test @MainActor func removedChannelsNoLongerNotifyTheMixer() {
        let old = Channel(id: "same")
        let replacement = Channel(id: "same")
        let mixer = Mixer(channels: [old])
        var changes: [MixerChange] = []
        let subscription = mixer.changes.sink { changes.append($0) }
        mixer.replaceChannels([replacement])
        old.volume.setValue(0.25)
        replacement.volume.setValue(0.5)
        mixer.replaceChannels([replacement])
        #expect(changes == [.channels, .channel("same")])
        #expect(mixer.channels[0] === replacement)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func masterParametersStayIndependentAndPublishOneBatch() {
        let channel = Channel(id: "first")
        let mixer = Mixer(channels: [channel])
        let width = mixer.master.width
        var changes: [MixerChange] = []
        let subscription = mixer.changes.sink { changes.append($0) }
        var settings = BusEQSettings()
        settings.gains[3] = -2.4
        settings.gainDB = -7.5
        settings.pan = 0.45
        settings.width = 1.35
        mixer.master.updateSettings(settings)
        #expect(changes == [.master])
        #expect(mixer.master.settings == settings)
        #expect(mixer.master.width === width)
        #expect(channel.settings == ChannelSettings())
        width.reset()
        #expect(mixer.master.settings.width == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func legacySettingsCanCreateAHeadlessMixerWithoutAudioObjects() throws {
        let channelSettings = try JSONDecoder().decode(ChannelSettings.self,
            from: Data(#"{"gains":[0,0,0,0,0,3.5,0,0,0,0],"volume":0.7,"eqEnabled":true}"#.utf8))
        let masterSettings = try JSONDecoder().decode(BusEQSettings.self,
            from: Data(#"{"gains":[-6,3,9,-3]}"#.utf8))
        let channel = Channel(id: "input", settings: channelSettings)
        let mixer = Mixer(channels: [channel], masterSettings: masterSettings)
        #expect(channel.settings == channelSettings)
        #expect(mixer.master.settings == masterSettings)
        let reopened = try JSONDecoder().decode(ChannelSettings.self,
            from: JSONEncoder().encode(channel.settings))
        #expect(reopened == channelSettings)
    }

    @Test @MainActor func releasingMixerDoesNotLeaveAChannelSubscription() {
        let channel = Channel(id: "input")
        weak var released: Mixer?
        do {
            let mixer = Mixer(channels: [channel])
            released = mixer
        }
        #expect(released == nil)
        channel.volume.setValue(0.25)
        #expect(channel.settings.volume == 0.25)
    }
}
