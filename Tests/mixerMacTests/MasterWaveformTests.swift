@testable import MixerAudio
import Testing
@testable import mixerMac

struct MasterWaveformTests {
    @Test func fixedDisplaySmoothingNeverOvershootsMeasuredEnvelope() {
        let target = Array(repeating: WaveformBin(minimum: -0.5, maximum: 0.5), count: 96)
        let immediate = WaveformEnvelope.smoothed(previous: WaveformEnvelope.silence, next: target, amount: 0)
        #expect(immediate == target)
        let smooth = WaveformEnvelope.smoothed(previous: WaveformEnvelope.silence, next: target, amount: WaveformDisplaySettings.smoothness)
        #expect(smooth.allSatisfy { $0.minimum > -0.5 && $0.maximum < 0.5 && $0.minimum <= $0.maximum })
        var settled = smooth
        for _ in 0..<110 { settled = WaveformEnvelope.smoothed(previous: settled, next: target, amount: WaveformDisplaySettings.smoothness) }
        #expect(settled.allSatisfy { abs($0.maximum - 0.5) < 0.001 })
    }

    @Test func stereoWaveformDoesNotCancelOppositePhaseOrNormalizeQuietAudio() {
        let left = [Float](repeating: 0.1, count: 4096)
        let right = [Float](repeating: -0.1, count: 4096)
        let bins = WaveformEnvelope.bins(left: left, right: right)
        #expect(bins.count == 96)
        #expect(bins.allSatisfy { $0.minimum == -0.1 && $0.maximum == 0.1 })
        let dc = WaveformEnvelope.bins(left: left, right: left)
        #expect(dc.allSatisfy { $0.minimum == 0.1 && $0.maximum == 0.1 })
    }

    @Test func waveformKeepsLastSampleTransientAndOverloadAmplitude() {
        var left = [Float](repeating: 0, count: 4096)
        var right = left
        left[0] = 2
        right[4095] = -0.25
        let bins = WaveformEnvelope.bins(left: left, right: right)
        #expect(bins.first?.maximum == 2)
        #expect(bins.last?.minimum == -0.25)
        #expect(bins[1..<95].allSatisfy { $0.minimum == 0 && $0.maximum == 0 })
    }

    @Test func absentAudioHasNoInventedWaveform() {
        #expect(WaveformEnvelope.bins(left: [], right: []) == WaveformEnvelope.silence)
        let zeros = [Float](repeating: 0, count: 4096)
        #expect(WaveformEnvelope.bins(left: zeros, right: zeros) == WaveformEnvelope.silence)
    }
}
