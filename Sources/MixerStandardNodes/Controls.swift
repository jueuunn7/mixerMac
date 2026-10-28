import MixerCore

public enum StandardNodeType {
    public static let gain = "standard.gain"
    public static let volume = "standard.volume"
    public static let pan = "standard.pan"
    public static let width = "standard.width"
    public static let parametricEQ = "standard.parametric-eq"
}

@MainActor
public final class GainNode: MixerNode {
    public let gain: Parameter
    public init(id: String, value: Float = 0) {
        gain = Parameter(value: value, range: -24...24, defaultValue: 0, unit: .decibels)
        super.init(id: id, typeID: StandardNodeType.gain, ports: [.stereoInput, .stereoOutput], parameters: ["gain": gain])
    }
}

@MainActor
public final class VolumeNode: MixerNode {
    public let volume: Parameter
    public init(id: String, value: Float = 1) {
        volume = Parameter(value: value, range: 0...1, defaultValue: 1, unit: .linearGain)
        super.init(id: id, typeID: StandardNodeType.volume, ports: [.stereoInput, .stereoOutput], parameters: ["volume": volume])
    }
}

@MainActor
public final class PanNode: MixerNode {
    public let pan: Parameter
    public init(id: String, value: Float = 0) {
        pan = Parameter(value: value, range: -1...1, defaultValue: 0, unit: .balance)
        super.init(id: id, typeID: StandardNodeType.pan, ports: [.stereoInput, .stereoOutput], parameters: ["pan": pan])
    }
}

@MainActor
public final class WidthNode: MixerNode {
    public let width: Parameter
    public init(id: String, value: Float = 1) {
        width = Parameter(value: value, range: 0...2, defaultValue: 1, unit: .ratio)
        super.init(id: id, typeID: StandardNodeType.width, ports: [.stereoInput, .stereoOutput], parameters: ["width": width])
    }
}
