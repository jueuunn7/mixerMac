import Testing
import Foundation
@preconcurrency import AVFAudio
@testable import mixerMac

struct PanTests {
    @Test(arguments: [Float(-1), 0, 1])
    func masterBalanceCombinesWithAppBalanceInsteadOfReplacingIt(master: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        input.frameLength = 4096
        for sample in 0..<4096 {
            input.floatChannelData![0][sample] = 0.25
            input.floatChannelData![1][sample] = -0.5
        }
        let bridge = try DriverAudioBridge(inputFeed: PCMFeed(), rate: 48_000)
        bridge.ingest(input.audioBufferList)
        bridge.setPan(-0.5)
        bridge.setMasterPan(master)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        output.frameLength = 1024
        bridge.render(1024, buffers: output.mutableAudioBufferList)
        #expect(abs(output.floatChannelData![0][1023] - 0.25 * min(1, 1 - master)) < 0.000001)
        #expect(abs(output.floatChannelData![1][1023] - Float(-0.25) * min(1, 1 + master)) < 0.000001)
    }

    @Test(arguments: [Float(-1), -0.5, 0, 0.5, 1], [44_100.0, 48_000.0])
    func actualBridgeBalancesStereoAndKeepsCentreUnity(pan: Float, rate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        input.frameLength = 4096
        for sample in 0..<4096 {
            input.floatChannelData![0][sample] = 0.25
            input.floatChannelData![1][sample] = -0.5
        }
        let bridge = try DriverAudioBridge(inputFeed: PCMFeed(), rate: rate)
        bridge.ingest(input.audioBufferList)
        bridge.setPan(pan)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        output.frameLength = 1024
        bridge.render(1024, buffers: output.mutableAudioBufferList)
        let expectedLeft = Float(0.25) * min(1, 1 - pan)
        let expectedRight = Float(-0.5) * min(1, 1 + pan)
        // After the 240-frame slew, all remaining frames reach the exact
        // target. Different L/R inputs prove there is no cross-channel fold.
        for sample in 300..<1024 {
            #expect(abs(output.floatChannelData![0][sample] - expectedLeft) < 0.000001)
            #expect(abs(output.floatChannelData![1][sample] - expectedRight) < 0.000001)
        }
        // Live movement is ramped rather than a discontinuous gain jump.
        if pan != 0 {
            #expect(abs(output.floatChannelData![0][0] - 0.25) < 0.002)
            #expect(abs(output.floatChannelData![1][0] + 0.5) < 0.003)
        }
    }

    @Test @MainActor func panPersistsAndOlderSettingsDefaultToCentre() throws {
        let suite = "mixerMac.Pan.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AudioApp(id: "pan.test", name: "Test", icon: nil, processes: [], isPlaying: false)
        let channel = AppAudioChannel(app: app, defaults: defaults)
        channel.settings.pan = -0.65
        let restored = AppAudioChannel(app: app, defaults: defaults)
        #expect(restored.settings.pan == -0.65)
        #expect(restored.settings.volume == 1)
        let legacy = Data(#"{"gains":[0,0,0,0,0,0,0,0,0,0],"volume":1,"eqEnabled":true}"#.utf8)
        #expect(try JSONDecoder().decode(AppChannelSettings.self, from: legacy).pan == 0)
    }
}
