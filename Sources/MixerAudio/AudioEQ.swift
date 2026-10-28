import MixerCore
import MixerStandardNodes
@preconcurrency import AVFAudio

public extension ChannelSettings {
    /// Shared by playback and the response inspector so the plot queries the
    /// same Apple EQ, including overlapping bands and trim.
    func applyEQ(to eq: AVAudioUnitEQ) {
        eq.bypass = false
        eq.globalGain = trimDB
        for index in eq.bands.indices {
            eq.bands[index].filterType = .parametric
            eq.bands[index].frequency = frequencies[index]
            eq.bands[index].bandwidth = bandwidths[index]
            eq.bands[index].gain = gains[index]
            eq.bands[index].bypass = !eqEnabled
        }
    }
}

public extension BusEQSettings {
    static func configure(_ eq: AVAudioUnitEQ) {
        precondition(eq.bands.count == frequencies.count, "Master EQ must have ten bands")
        for index in eq.bands.indices {
            eq.bands[index].frequency = frequencies[index]
            eq.bands[index].bandwidth = 1
            eq.bands[index].filterType = .parametric
            eq.bands[index].bypass = false
        }
    }

    func apply(to eq: AVAudioUnitEQ) {
        precondition(eq.bands.count == Self.frequencies.count && gains.count == Self.frequencies.count,
                     "Master EQ must have ten bands and ten gains")
        for index in eq.bands.indices {
            eq.bands[index].gain = (gains[index].isFinite ? min(24, max(-24, gains[index])) : 0)
            eq.bands[index].frequency = bandFrequencies[index]
            eq.bands[index].bandwidth = bandwidths[index]
        }
        // No automatic headroom: a boost remains a boost in the rendered output.
        eq.globalGain = (gainDB.isFinite ? min(24, max(-24, gainDB)) : 0)
        eq.bypass = !enabled
    }
}
