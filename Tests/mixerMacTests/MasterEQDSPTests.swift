@testable import MixerAudio
import MixerCore
import Testing
import Foundation
@preconcurrency import AVFAudio
@testable import mixerMac

struct MasterEQDSPTests {
    @Test @MainActor func masterGainPersistsAndMatchesDetailResponse() throws {
        var settings = BusEQSettings()
        settings.gainDB = -7.5
        let restored = try JSONDecoder().decode(BusEQSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.gainDB == -7.5)
        let response = try ChannelEQResponse().decibels(settings: restored.detailSettings,
            frequencies: [100, 1000, 10_000], sampleRate: 48_000)
        #expect(response.allSatisfy { abs($0 + 7.5) < 0.001 })
        var edited = restored
        var detail = edited.detailSettings
        detail.gains[4] = 3
        edited.detailSettings = detail
        #expect(edited.gainDB == -7.5)
        detail.trimDB = 30
        edited.detailSettings = detail
        #expect(edited.gainDB == 24)
        let legacy = try JSONDecoder().decode(BusEQSettings.self,
            from: Data(#"{"gains":[0,0,0,0]}"#.utf8))
        #expect(legacy.gainDB == 0)
    }

    @Test(arguments: [Float(-24), 0, 24]) @MainActor
    func masterGainChangesRenderedAudio(gainDB: Float) throws {
        let processor = AppChannelProcessor()
        var master = BusEQSettings()
        master.gainDB = gainDB
        processor.apply(ChannelSettings(), audible: true, master: 1, sampleRate: 48_000, masterEQ: master)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        source.frameLength = 4096
        let samples = try #require(source.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<4096 { samples[channel][frame] = 0.01 * Float(sin(2 * Double.pi * Double(frame) / 32)) }
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(processor.masterEQ)
        engine.connect(player, to: processor.masterEQ, format: format)
        engine.connect(processor.masterEQ, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(source, at: nil, options: .loops)
        player.play()
        for _ in 0..<5 { #expect(try engine.renderOffline(4096, to: output) == .success) }
        let rendered = try #require(output.floatChannelData)
        for channel in 0..<2 {
            let peak = (0..<4096).map { abs(rendered[channel][$0]) }.max() ?? 0
            #expect(abs(20 * log10(peak / 0.01) - gainDB) < 0.05)
        }
    }

    @Test @MainActor func masterBandsMatchAppEQ() {
        #expect(BusEQSettings.frequencies == EQSettings.frequencies)
        #expect(BusEQSettings.labels == ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"])
        let eq = AVAudioUnitEQ(numberOfBands: BusEQSettings.frequencies.count)
        BusEQSettings.configure(eq)
        let settings = BusEQSettings()
        settings.apply(to: eq)
        #expect(settings.gains == [Float](repeating: 0, count: 10))
        #expect(!eq.bypass)
        #expect(eq.globalGain == 0)
        for (index, band) in eq.bands.enumerated() {
            #expect(band.frequency == BusEQSettings.frequencies[index])
            #expect(band.filterType == .parametric)
            #expect(band.bandwidth == 1)
            #expect(!band.bypass)
        }
    }

    @Test func legacyShelvesExtendAndMidsInterpolateInOctaves() throws {
        let data = Data(#"{"gains":[-6,3,9,-3],"enabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(BusEQSettings.self, from: data)
        #expect(settings.gains.count == 10)
        #expect(Array(settings.gains.prefix(3)) == [-6, -6, -6])
        #expect(Array(settings.gains.suffix(3)) == [-3, -3, -3])
        let intervals: [(Int, Float, Float, Float, Float)] = [
            (3, 180, 350, -6, 3), (4, 350, 1100, 3, 9),
            (5, 350, 1100, 3, 9), (6, 1100, 3000, 9, -3)
        ]
        for (index, lowHz, highHz, lowGain, highGain) in intervals {
            let fraction = log2(BusEQSettings.frequencies[index] / lowHz) / log2(highHz / lowHz)
            #expect(abs(settings.gains[index] - (lowGain + fraction * (highGain - lowGain))) < 0.0001)
        }
        // Encoding writes ten gains; subsequent reads never migrate them again.
        let roundTrip = try JSONDecoder().decode(BusEQSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
    }

    @Test(arguments: [4, 10])
    func restorationAlwaysEnablesAndPreservesSavedTone(count: Int) throws {
        let suite = "mixerMac.MasterEQDSPTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved: [String: Any] = ["gains": Array(repeating: 6, count: count), "enabled": false]
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: "master.eq")
        let restored = BusEQSettings.restored(defaults: defaults)
        #expect(restored.enabled)
        #expect(restored.gains == [Float](repeating: 6, count: 10))
    }

    @Test func malformedSavedBandCountFallsBackToEnabledFlatEQ() throws {
        let suite = "mixerMac.MasterEQDSPTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"gains":[6,3],"enabled":false}"#.utf8), forKey: "master.eq")
        #expect(BusEQSettings.restored(defaults: defaults) == BusEQSettings())
    }

    @Test func masterGainLimitsHaveNoAutomaticHeadroom() {
        let eq = AVAudioUnitEQ(numberOfBands: BusEQSettings.frequencies.count)
        BusEQSettings.configure(eq)
        var settings = BusEQSettings()
        settings.gains = [36, -36, 24, -24, 6, -6, 0, 0, 0, 0]
        settings.apply(to: eq)
        #expect(eq.bands.map(\.gain) == [24, -24, 24, -24, 6, -6, 0, 0, 0, 0])
        #expect(eq.globalGain == 0)
        #expect(!eq.bypass)
    }

    @Test(arguments: [-4.01, -4.0, -3.99, -0.01, 0.0, 0.01]) @MainActor
    func redLEDThresholdsNeverRoundUp(dbFS: Double) {
        let level = SpectrumAnalyzer.meterLevel(Float(pow(10, dbFS / 20)))
        let displayed = MixerMeterScale.decibels(for: level)
        #expect((displayed >= MixerMeterScale.channelWarningDB) == (dbFS >= -4))
        #expect((displayed >= MixerMeterScale.masterPeakDB) == (dbFS >= 0))
        // These assertions exercise the actual published levels, catching rounding
        // that fabricates a warning or full-scale peak just below its threshold.
        let metrics = ChannelAudioMetrics()
        metrics.setLevel(level, peak: level)
        for published in [metrics.level, metrics.heldPeak] {
            let displayed = MixerMeterScale.decibels(for: published)
            #expect((displayed >= MixerMeterScale.channelWarningDB) == (dbFS >= -4))
            #expect((displayed >= MixerMeterScale.masterPeakDB) == (dbFS >= 0))
        }
    }

    @Test func fullScalePeakHoldsForOneAndAHalfSecondsThenReleases() {
        var hold = MeterPeakHold()
        hold.update(1, now: 10)
        hold.update(0, now: 11.499)
        #expect(hold.level == 1)
        hold.update(0, now: 11.5)
        #expect(hold.level == 1)
        hold.update(0, now: 11.6)
        #expect(abs(hold.level - 0.965) < 0.0001)
        #expect(MixerMeterScale.decibels(for: hold.level) < MixerMeterScale.masterPeakDB)
        hold.update(1, now: 12)
        hold.update(0, now: 13.5)
        #expect(hold.level == 1)
    }
}
