import MixerCore

@MainActor
public final class ExternalGain: MixerNode {
    public let amount: Parameter
    public init(id: String) {
        amount = Parameter(value: 1, range: 0...4, defaultValue: 1, unit: .linearGain)
        super.init(id: id, typeID: "example.gain", ports: [.stereoInput, .stereoOutput], parameters: ["amount": amount])
    }
}

@MainActor
public final class ExternalThreshold: Parameter {
    public init() { super.init(value: -12, range: -60...0, defaultValue: -12, unit: .decibels, step: 0.5) }
}

@MainActor
public final class ExternalInput: MixerNode {
    public init(id: String, channels: Int = 2, signal: String = "audio.float32") {
        super.init(id: id, typeID: "example.input", ports: [AudioPort(id: "output", direction: .output, channels: channels, signal: signal)])
    }
}

@MainActor
public final class ExternalOutput: MixerNode {
    public init(id: String) { super.init(id: id, typeID: "example.output", ports: [.stereoInput]) }
}
