import MixerCore

public extension StandardNodeType {
    static let filter = "standard.filter"
    static let crunch = "standard.crunch"
    static let filterRouter = "standard.filter-router"
    static let filterBank = "standard.filter-bank"
}

public enum ConsoleFilterEffect {
    public static let labels = ["LPF", "BPF", "HPF", "ECHO", "REVERB"]
    public static let filterModes = 0...2
    public static let echo = 3
    public static let reverb = 4
}

@MainActor
public final class FilterNode: MixerNode {
    public let mode = Parameter(value: 0, range: 0...4, defaultValue: 0, unit: .init(rawValue: "filterMode"), step: 1)
    public let frequency = Parameter(value: 1000, range: 20...20000, defaultValue: 1000, unit: .hertz)
    public let resonance = Parameter(value: 0, range: 0...1, defaultValue: 0, unit: .ratio)
    public let time = Parameter(value: 0.5, range: 0.01...2, defaultValue: 0.5, unit: .init(rawValue: "seconds"))
    public let mix = Parameter(value: 0.35, range: 0...1, defaultValue: 0.35, unit: .ratio)

    public init(id: String) {
        super.init(id: id, typeID: StandardNodeType.filter, ports: [.stereoInput, .stereoOutput],
            parameters: ["mode": mode, "frequency": frequency, "resonance": resonance,
                         "time": time, "mix": mix])
    }
}

@MainActor
public final class CrunchNode: MixerNode {
    public let amount = Parameter(value: 0, range: 0...1, defaultValue: 0, unit: .ratio)

    public init(id: String) {
        super.init(id: id, typeID: StandardNodeType.crunch, ports: [.stereoInput, .stereoOutput], parameters: ["amount": amount])
    }
}

@MainActor
public final class FilterRouterNode: MixerNode {
    public let selection = Parameter(value: 0, range: 0...2, defaultValue: 0, unit: .init(rawValue: "filterRoute"), step: 1)

    public init(id: String) {
        super.init(id: id, typeID: StandardNodeType.filterRouter,
            ports: [.stereoInput, AudioPort(id: "dry", direction: .output),
                    AudioPort(id: "filter1", direction: .output), AudioPort(id: "filter2", direction: .output)],
            parameters: ["selection": selection])
    }
}

@MainActor
public final class ConsoleFilterBank: MixBus {
    public let crunch: CrunchNode
    public let filter: FilterNode

    public init(id: String) {
        crunch = CrunchNode(id: id + ".crunch")
        filter = FilterNode(id: id + ".filter")
        super.init(id: id, typeID: StandardNodeType.filterBank, nodes: [crunch, filter])
        setBypassed(true)
    }

    public override func validateProcessingNodes(_ nodes: [MixerNode]) throws {
        guard nodes.count == 2, nodes[0] === crunch, nodes[1] === filter else { throw PresetError.requiredNodeRemoved(id) }
    }
}
