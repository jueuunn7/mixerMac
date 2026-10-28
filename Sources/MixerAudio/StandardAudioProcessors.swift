import AudioToolbox
import MixerCore
import MixerStandardNodes
@preconcurrency import AVFAudio

@MainActor
private final class GainProcessor: AudioProcessor {
    let parameter: Parameter
    let eq: AVAudioUnitEQ
    init(model: MixerNode, parameter: Parameter) {
        self.parameter = parameter
        eq = AVAudioUnitEQ(numberOfBands: 0)
        super.init(model: model, nodes: [eq], inputs: ["input": AudioEndpoint(eq)],
            outputs: ["output": AudioEndpoint(eq)], bypassUnits: [eq])
    }
    override func applyParameters(bypassed: Bool) {
        eq.globalGain = parameter.value
    }
}

@MainActor
private final class VolumeProcessor: AudioProcessor {
    let volume: VolumeNode
    let mixer = AVAudioMixerNode()
    init(_ volume: VolumeNode) {
        self.volume = volume
        super.init(model: volume, nodes: [mixer], inputs: ["input": AudioEndpoint(mixer)], outputs: ["output": AudioEndpoint(mixer)])
    }
    override func applyParameters(bypassed: Bool) { mixer.outputVolume = bypassed ? 1 : volume.volume.value }
}

@MainActor
private final class EQProcessor: AudioProcessor {
    let filter: ParametricEQNode
    let eq: AVAudioUnitEQ
    init(_ filter: ParametricEQNode) {
        self.filter = filter
        eq = AVAudioUnitEQ(numberOfBands: filter.bands.count)
        super.init(model: filter, nodes: [eq], inputs: ["input": AudioEndpoint(eq)],
            outputs: ["output": AudioEndpoint(eq)], bypassUnits: [eq])
    }
    override func applyParameters(bypassed: Bool) {
        for (index, band) in filter.bands.enumerated() {
            eq.bands[index].filterType = .parametric
            eq.bands[index].frequency = band.frequency.value
            eq.bands[index].gain = band.gain.value
            eq.bands[index].bandwidth = band.bandwidth.value
            eq.bands[index].bypass = false
        }
    }
}

@MainActor
private final class StereoProcessor: AudioProcessor {
    let parameter: Parameter
    let isWidth: Bool
    let unit: StereoAudioUnit
    init(model: MixerNode, parameter: Parameter, isWidth: Bool) throws {
        self.parameter = parameter
        self.isWidth = isWidth
        let effect = AVAudioUnitEffect(audioComponentDescription: StereoAudioUnit.component)
        guard let unit = effect.auAudioUnit as? StereoAudioUnit else { throw AudioGraphError.incompatibleProcessor(model.id) }
        self.unit = unit
        super.init(model: model, nodes: [effect], inputs: ["input": AudioEndpoint(effect)],
            outputs: ["output": AudioEndpoint(effect)], bypassUnits: [effect])
    }
    override func applyParameters(bypassed: Bool) { unit.set(pan: isWidth ? 0 : parameter.value, width: isWidth ? parameter.value : 1) }
}

public enum StandardAudioProcessors {
    @MainActor
    public static func make() throws -> AudioProcessorRegistry {
        let registry = AudioProcessorRegistry()
        try register(in: registry)
        return registry
    }

    @MainActor
    public static func register(in registry: AudioProcessorRegistry) throws {
        AUAudioUnit.registerSubclass(StereoAudioUnit.self, as: StereoAudioUnit.component,
            name: "mixerMac: Stereo", version: 1)
        AUAudioUnit.registerSubclass(CrunchAudioUnit.self, as: CrunchAudioUnit.component, name: "mixerMac: Crunch", version: 1)
        try registry.register(StandardNodeType.filter, nodeType: FilterNode.self) { FilterProcessor($0) }
        try registry.register(StandardNodeType.crunch, nodeType: CrunchNode.self) { try CrunchProcessor($0) }
        try registry.register(StandardNodeType.filterRouter, nodeType: FilterRouterNode.self) { FilterRouterProcessor($0) }
        try registry.register(StandardNodeType.gain, nodeType: GainNode.self) { GainProcessor(model: $0, parameter: $0.gain) }
        try registry.register(StandardNodeType.volume, nodeType: VolumeNode.self) { VolumeProcessor($0) }
        try registry.register(StandardNodeType.parametricEQ, nodeType: ParametricEQNode.self) { EQProcessor($0) }
        try registry.register(StandardNodeType.pan, nodeType: PanNode.self) { try StereoProcessor(model: $0, parameter: $0.pan, isWidth: false) }
        try registry.register(StandardNodeType.width, nodeType: WidthNode.self) { try StereoProcessor(model: $0, parameter: $0.width, isWidth: true) }
    }
}
