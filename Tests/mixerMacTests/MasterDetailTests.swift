@testable import MixerAudio
import MixerCore
import MixerStandardNodes
import Testing
import Foundation
import SwiftUI
@preconcurrency import AVFAudio
@testable import mixerMac

struct MasterDetailTests {
    @Test func eqFaderHasCenterZeroAndFullBipolarRange() {
        #expect(EQFaderScale.position(for: 0) == 0.5)
        #expect(EQFaderScale.position(for: 24) == 1)
        #expect(EQFaderScale.position(for: -24) == 0)
        #expect(EQFaderScale.gain(at: 1) == 24)
        #expect(EQFaderScale.gain(at: 0.5) == 0)
        #expect(EQFaderScale.gain(at: 0) == -24)
        #expect(EQFaderScale.gain(at: 2) == 24)
        #expect(EQFaderScale.gain(at: -1) == -24)
        #expect(EQFaderScale.gain(at: 0.503) == 0)
        for value: Float in [-24, -18.3, -6.7, 0, 3.7, 12.4, 24] {
            #expect(abs(EQFaderScale.gain(at: EQFaderScale.position(for: value)) - value) < 0.001)
        }
    }

    @Test @MainActor func sharedMasterEditorBindingSavesAndReachesAllOutputEQs() throws {
        let suite = "mixerMac.MasterDetail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
        let binding = Binding<ChannelSettings>(get: { model.masterEQ.detailSettings }, set: { model.masterEQ.detailSettings = $0 })
        setDetailGain(3.7, band: 5, settings: binding)
        binding.wrappedValue.frequencies[5] = 1234.5
        binding.wrappedValue.bandwidths[5] = 0.35
        binding.wrappedValue.pan = 0.45
        let restored = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
        #expect(restored.masterEQ.gains[5] == 3.7)
        #expect(restored.masterEQ.bandFrequencies[5] == 1234.5)
        #expect(restored.masterEQ.bandwidths[5] == 0.35)
        #expect(restored.masterEQ.pan == 0.45)
        #expect(restored.masterEQ.detailSettings.pan == 0.45)
        #expect(restored.masterEQ.detailSettings.trimDB == 0)
        #expect(restored.masterEQ.detailSettings.volume == 1)
        var neutralPan = restored.masterEQ
        neutralPan.pan = 0
        let peak = try renderedConsolePeak(master: neutralPan, frequency: 1234.5, frames: 48000, amplitude: 0.01)
        #expect(abs(20 * log10(peak / 0.01) - 3.7) < 0.05)
        let response = try ChannelEQResponse().decibels(settings: restored.masterEQ.detailSettings,
            frequencies: [1234.5], sampleRate: 48_000)
        #expect(abs(response[0] - 3.7) < 0.001)
    }

    @Test @MainActor func faderEditsNeverAddHiddenMasterAttenuation() throws {
        var master = BusEQSettings()
        let binding = Binding<ChannelSettings>(get: { master.detailSettings }, set: { master.detailSettings = $0 })
        setDetailGain(-24, band: 0, settings: binding)
        setDetailGain(24, band: 9, settings: binding)
        let eq = AVAudioUnitEQ(numberOfBands: 10)
        BusEQSettings.configure(eq)
        master.apply(to: eq)
        #expect(eq.bands[0].gain == -24)
        #expect(eq.bands[9].gain == 24)
        #expect(eq.globalGain == 0)
        let data = try JSONEncoder().encode(master)
        let reopened = try JSONDecoder().decode(BusEQSettings.self, from: data)
        #expect(reopened == master)
    }
}
