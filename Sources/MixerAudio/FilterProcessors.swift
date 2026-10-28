import AudioToolbox
import MixerCore
import MixerStandardNodes
@preconcurrency import AVFAudio

@MainActor
final class FilterProcessor: AudioProcessor {
    let filter: FilterNode
    let eq = AVAudioUnitEQ(numberOfBands: 1)

    init(_ filter: FilterNode) {
        self.filter = filter
        super.init(model: filter, nodes: [eq], inputs: ["input": AudioEndpoint(eq)],
            outputs: ["output": AudioEndpoint(eq)], bypassUnits: [eq])
    }

    override func applyParameters(bypassed: Bool) {
        let band = eq.bands[0]
        band.filterType = [.resonantLowPass, .bandPass, .resonantHighPass][Int(filter.mode.value)]
        band.frequency = min(filter.frequency.value, Float(eq.outputFormat(forBus: 0).sampleRate * 0.45))
        band.bandwidth = 2 - 1.9 * filter.resonance.value
        band.bypass = false
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
