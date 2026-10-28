@testable import MixerAudio
import MixerCore
import MixerStandardNodes
import Testing
import Foundation
@preconcurrency import AVFAudio
@testable import mixerMac

struct StereoWidthTests {
    private func rendered(width: Float, left: Float = 0.25, right: Float = -0.5,
                          appPan: Float = 0, masterPan: Float = 0) throws -> (Float, Float) {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        input.frameLength = 4096
        for sample in 0..<4096 {
            input.floatChannelData![0][sample] = left
            input.floatChannelData![1][sample] = right
        }
        let bridge = try DriverAudioBridge(inputFeed: PCMFeed(), rate: 48_000)
        bridge.setPan(appPan)
        bridge.setMasterWidth(width)
        bridge.setMasterPan(masterPan)
        bridge.ingest(input.audioBufferList)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        output.frameLength = 1024
        bridge.render(1024, buffers: output.mutableAudioBufferList)
        return (output.floatChannelData![0][1023], output.floatChannelData![1][1023])
    }

    @Test func nativeWidthProducesMonoOriginalAndWiderStereo() throws {
        let cases: [(Float, Float, Float)] = [
            (0, -0.125, -0.125), (0.5, 0.0625, -0.3125),
            (1, 0.25, -0.5), (1.5, 0.4375, -0.6875), (2, 0.625, -0.875)
        ]
        for (width, expectedLeft, expectedRight) in cases {
            let (left, right) = try rendered(width: width)
            #expect(abs(left - expectedLeft) < 0.000001)
            #expect(abs(right - expectedRight) < 0.000001)
        }
    }

    @Test func widthPreservesMonoAndRunsBetweenChannelAndMasterPan() throws {
        for width: Float in [0, 1, 2] {
            let (left, right) = try rendered(width: width, left: 0.25, right: 0.25)
            #expect(left == 0.25)
            #expect(right == 0.25)
        }
        let mono = try rendered(width: 0, appPan: -0.5)
        #expect(abs(mono.0) < 0.000001)
        #expect(abs(mono.1) < 0.000001)
        let balance = try rendered(width: 2, masterPan: 1)
        #expect(balance.0 == 0)
        #expect(abs(balance.1 + 0.875) < 0.000001)
    }

    @Test @MainActor func masterWidthPersistsWhileEQDetailEditsPreserveIt() throws {
        let suite = "mixerMac.Width.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
        model.masterEQ.width = 1.35
        model.masterEQ.detailSettings.gains[3] = -2.4
        let restored = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
        #expect(restored.masterEQ.width == 1.35)
        #expect(restored.masterEQ.gains[3] == -2.4)
        let old = Data(#"{"gains":[0,0,0,0,0,0,0,0,0,0],"enabled":true}"#.utf8)
        #expect(try JSONDecoder().decode(BusEQSettings.self, from: old).width == 1)
    }
}
