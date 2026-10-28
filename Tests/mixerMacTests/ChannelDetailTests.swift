@testable import MixerAudio
import MixerCore
import MixerStandardNodes
import Testing
import Foundation
import SwiftUI
@preconcurrency import AVFAudio
@testable import mixerMac

struct ChannelDetailTests {
    @Test @MainActor func consoleResetRestoresToneAndPersistsWithoutChangingMixState() throws {
        let domain = "mixerMac.ResetTone.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AudioApp(id: "reset", name: "Reset", icon: nil, processes: [], isPlaying: false)
        let channel = AppAudioChannel(app: app, defaults: defaults)
        var edited = ChannelSettings()
        edited.pan = 0.7
        edited.width = 1.8
        edited.trimDB = 9
        edited.gains[3] = 12
        edited.frequencies[3] = 333
        edited.bandwidths[3] = 2
        edited.volume = 0.4
        edited.isMuted = true
        edited.isSolo = true
        channel.settings = edited
        var updates = 0
        let subscription = channel.core.changes.sink { _ in updates += 1 }
        channel.core.resetTone()
        var expected = ChannelSettings()
        expected.volume = 0.4
        expected.isMuted = true
        expected.isSolo = true
        #expect(channel.settings == expected)
        #expect(updates == 1)
        let restored = AppAudioChannel(app: app, defaults: defaults)
        #expect(restored.settings == expected)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func signalHistoryPreservesPeaksAboveFullScale() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        for index in 0..<4096 {
            buffer.floatChannelData![0][index] = 2
            buffer.floatChannelData![1][index] = -2
        }
        let feed = PCMFeed()
        feed.push(buffer)
        let detail = ChannelDetailModel()
        detail.tick(settings: ChannelSettings(), feed: feed, isProcessing: true)
        #expect(abs(detail.peakDB - 6.0206) < 0.001)
        #expect(detail.history.last == detail.peakDB)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 114)
        let zero = DetailAudioTrace.yPosition(0, plot: rect, ceiling: 24)
        let trace = DetailAudioTrace(levels: [detail.peakDB, 0], plot: rect, history: true, ceiling: 24)
        #expect(trace.path(in: rect).boundingRect.minY < zero)
        #expect(DetailAudioTrace.yPosition(24, plot: rect, ceiling: 24) == rect.minY)
        #expect(DetailAudioTrace.yPosition(-90, plot: rect, ceiling: 24) == rect.maxY)
    }

    @Test @MainActor func graphDragPublishesOneCompleteBandEdit() throws {
        let domain = "mixerMac.GraphDrag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AudioApp(id: "drag", name: "Drag", icon: nil, processes: [], isPlaying: false)
        let channel = AppAudioChannel(app: app, defaults: defaults)
        let settings = Binding(get: { channel.settings }, set: { channel.settings = $0 })
        var edits: [(Float, Float)] = []
        let subscription = channel.core.changes.sink { _ in
            edits.append((channel.settings.frequencies[5], channel.settings.gains[5]))
        }
        setDetailBand(5, frequency: 1234, gain: 3.26, settings: settings)
        #expect(edits.count == 1)
        #expect(edits.first?.0 == 1234)
        #expect(edits.first?.1 == 3.3)
        let restored = AppAudioChannel(app: app, defaults: defaults)
        #expect(restored.settings == channel.settings)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func neutralProcessingPreservesPCM() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        source.frameLength = 4096
        for index in 0..<4096 {
            source.floatChannelData![0][index] = Float((index * 1664525) % 65536 - 32768) / 65536
            source.floatChannelData![1][index] = Float((index * 1013904223) % 65536 - 32768) / 65536
        }
        let output = try renderConsolePCM(source)
        var maximumError: Float = 0
        for channel in 0..<2 {
            for index in 0..<4096 {
                maximumError = max(maximumError, abs(source.floatChannelData![channel][index] - output.floatChannelData![channel][index]))
            }
        }
        #expect(maximumError < 0.000_001)
    }

    @Test(arguments: [-24.0, 24.0]) @MainActor
    func expandedGainRangeSurvivesRestoreAndMatchesResponse(gain: Double) throws {
        let suite = "mixerMac.ExpandedGain.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AudioApp(id: "expanded.test", name: "Test", icon: nil, processes: [], isPlaying: false)
        let channel = AppAudioChannel(app: app, defaults: defaults)
        channel.core.equalizer.bands[5].gain.setValue(Float(gain))
        let restored = AppAudioChannel(app: app, defaults: defaults)
        #expect(restored.settings.gains[5] == Float(gain))
        let rendered = try renderedConsolePeak(settings: restored.settings, frequency: 1000, frames: 4800, amplitude: 0.01)
        #expect(abs(20 * log10(rendered / 0.01) - Float(gain)) < 0.05)
        let response = try ChannelEQResponse().decibels(settings: restored.settings, frequencies: [1000], sampleRate: 48_000)
        #expect(abs(response[0] - gain) < 0.001)
    }

    @Test func displaySmoothingSettlesWithoutInventingPeaks() {
        var smoother = SpectrumDisplaySmoother()
        let target = [Float](repeating: -12, count: SpectrumAnalyzer.pointCount)
        let first = smoother.update(target)
        #expect(first.allSatisfy { $0 > -90 && $0 < -12 })
        for _ in 0..<15 { _ = smoother.update(target) }
        #expect(smoother.values.allSatisfy { abs($0 + 12) < 0.01 })
        let release = smoother.update([Float](repeating: -90, count: SpectrumAnalyzer.pointCount))
        #expect(release.allSatisfy { $0 > -90 && $0 < -12 })
        for _ in 0..<40 { _ = smoother.update([Float](repeating: -90, count: SpectrumAnalyzer.pointCount)) }
        #expect(smoother.values.allSatisfy { abs($0 + 90) < 0.001 })
    }

    @Test @MainActor func fineSettingsPersistAndReachPlayback() throws {
        let suite = "mixerMac.Detail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AudioApp(id: "test.detail", name: "Test", icon: nil, processes: [], isPlaying: false)
        let channel = AppAudioChannel(app: app, defaults: defaults)
        channel.settings.frequencies[5] = 1234.5
        channel.settings.bandwidths[5] = 0.35
        channel.core.equalizer.bands[5].gain.setValue(3.7)
        let restored = AppAudioChannel(app: app, defaults: defaults)
        #expect(restored.settings.frequencies[5] == 1234.5)
        #expect(restored.settings.bandwidths[5] == 0.35)
        #expect(restored.settings.gains[5] == 3.7)
        let rendered = try renderedConsolePeak(settings: restored.settings, frequency: 1234.5, frames: 48000, amplitude: 0.01)
        #expect(abs(20 * log10(rendered / 0.01) - 3.7) < 0.05)
    }

    @Test func olderSettingsKeepTheirToneAndDefaultBandShape() throws {
        let data = Data(#"{"gains":[0,0,0,0,0,3.5,0,0,0,0],"volume":0.7,"eqEnabled":true}"#.utf8)
        let restored = try JSONDecoder().decode(ChannelSettings.self, from: data)
        #expect(restored.gains[5] == 3.5)
        #expect(restored.frequencies == EQSettings.frequencies)
        #expect(restored.bandwidths == Array(repeating: 1, count: 10))
    }

    @Test func detailReadsDoNotStealConsoleMeterPeaks() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        for channel in 0..<2 {
            for sample in 0..<4096 { buffer.floatChannelData![channel][sample] = 0.5 }
        }
        let feed = PCMFeed()
        feed.push(buffer)
        #expect(try #require(feed.snapshot(consumingPeaks: false)).peak == 0.5)
        #expect(try #require(feed.snapshot(consumingPeaks: false)).peak == 0.5)
        #expect(try #require(feed.snapshot(includeSamples: false)).peak == 0.5)
        #expect(try #require(feed.snapshot(includeSamples: false)).peak == 0)
    }

    @Test(arguments: [44_100.0, 48_000.0]) @MainActor
    func responseMatchesRenderedAppleEQ(sampleRate: Double) throws {
        var settings = ChannelSettings()
        settings.trimDB = -2
        settings.frequencies[5] = 1200
        settings.bandwidths[5] = 0.35
        settings.gains[5] = 7.3
        settings.gains[8] = -4.1
        let reader = ChannelEQResponse()
        for frequency in [1200.0, 6300, 15_000] {
            let plotted = try #require(reader.decibels(settings: settings, frequencies: [frequency], sampleRate: sampleRate).first)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let eq = AVAudioUnitEQ(numberOfBands: 10)
            settings.applyEQ(to: eq)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
            engine.attach(player); engine.attach(eq)
            engine.connect(player, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768))
            source.frameLength = 32768
            for sample in 0..<32768 {
                let value = Float(0.01 * sin(2 * Double.pi * frequency * Double(sample) / sampleRate))
                source.floatChannelData![0][sample] = value
                source.floatChannelData![1][sample] = value
            }
            let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            try engine.start()
            defer { engine.stop() }
            player.scheduleBuffer(source)
            player.play()
            for _ in 0..<5 { #expect(try engine.renderOffline(4096, to: rendered) == .success) }
            var inputPower = 0.0, outputPower = 0.0
            for sample in 0..<4096 {
                let original = Double(source.floatChannelData![0][16384 + sample])
                let output = Double(rendered.floatChannelData![0][sample])
                inputPower += original * original
                outputPower += output * output
            }
            let measured = 10 * log10(outputPower / inputPower)
            #expect(abs(plotted - measured) < 0.08)
        }
        let flat = try reader.decibels(settings: ChannelSettings(), frequencies: [20, 1000, 16_000], sampleRate: sampleRate)
        #expect(flat.allSatisfy { abs($0) < 0.0001 })
    }
}
