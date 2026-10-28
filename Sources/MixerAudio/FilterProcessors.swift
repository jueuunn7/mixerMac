import AudioToolbox
import MixerCore
import MixerStandardNodes
@preconcurrency import AVFAudio

@MainActor
final class FilterProcessor: AudioProcessor {
    let filter: FilterNode
    let eq = AVAudioUnitEQ(numberOfBands: 1)
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    private var reverbPreset: AVAudioUnitReverbPreset?

    init(_ filter: FilterNode) {
        self.filter = filter
        reverb.loadFactoryPreset(.mediumHall)
        reverbPreset = .mediumHall
        super.init(model: filter, nodes: [eq, delay, reverb], inputs: ["input": AudioEndpoint(eq)],
            outputs: ["output": AudioEndpoint(reverb)], bypassUnits: [eq, delay, reverb],
            connections: [
                (AudioEndpoint(eq), AudioEndpoint(delay)),
                (AudioEndpoint(delay), AudioEndpoint(reverb))
            ])
    }

    override func applyParameters(bypassed: Bool) {
        let mode = Int(filter.mode.value)
        let band = eq.bands[0]
        band.filterType = [.resonantLowPass, .bandPass, .resonantHighPass][min(mode, 2)]
        band.frequency = min(filter.frequency.value, Float(eq.outputFormat(forBus: 0).sampleRate * 0.45))
        band.bandwidth = 2 - 1.9 * filter.resonance.value
        band.bypass = false

        delay.delayTime = TimeInterval(filter.time.value)
        delay.feedback = min(95, filter.resonance.value * 95)
        delay.wetDryMix = filter.mix.value * 100
        delay.lowPassCutoff = 18_000

        let preset: AVAudioUnitReverbPreset = filter.time.value < 0.7 ? .smallRoom
            : filter.time.value < 1.35 ? .mediumHall : .largeHall
        if reverbPreset != preset {
            reverb.loadFactoryPreset(preset)
            reverbPreset = preset
        }
        reverb.wetDryMix = filter.mix.value * 100

        eq.bypass = mode > ConsoleFilterEffect.filterModes.upperBound
        delay.bypass = mode != ConsoleFilterEffect.echo
        reverb.bypass = mode != ConsoleFilterEffect.reverb
    }
}

@MainActor
final class CrunchProcessor: AudioProcessor {
    let crunch: CrunchNode
    let unit: CrunchAudioUnit

    init(_ crunch: CrunchNode) throws {
        self.crunch = crunch
        let effect = AVAudioUnitEffect(audioComponentDescription: CrunchAudioUnit.component)
        guard let unit = effect.auAudioUnit as? CrunchAudioUnit else { throw AudioGraphError.incompatibleProcessor(crunch.id) }
        self.unit = unit
        super.init(model: crunch, nodes: [effect], inputs: ["input": AudioEndpoint(effect)],
            outputs: ["output": AudioEndpoint(effect)], bypassUnits: [effect])
    }

    override func applyParameters(bypassed: Bool) { unit.set(amount: crunch.amount.value) }
}

@MainActor
final class FilterRouterProcessor: AudioProcessor {
    let router: FilterRouterNode
    let input = AVAudioMixerNode()
    let branches = [AVAudioMixerNode(), AVAudioMixerNode(), AVAudioMixerNode()]

    init(_ router: FilterRouterNode) {
        self.router = router
        let source = AudioEndpoint(input)
        super.init(model: router, nodes: [input] + branches, inputs: ["input": AudioEndpoint(input)],
            outputs: ["dry": AudioEndpoint(branches[0]), "filter1": AudioEndpoint(branches[1]), "filter2": AudioEndpoint(branches[2])],
            connections: branches.map { (source, AudioEndpoint($0)) })
    }

    override func applyParameters(bypassed: Bool) {
        let selection = bypassed ? 0 : Int(router.selection.value)
        for index in branches.indices { branches[index].outputVolume = index == selection ? 1 : 0 }
    }
}
