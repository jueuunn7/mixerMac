import MixerCore
@preconcurrency import AVFAudio

public struct AudioEndpoint {
    public let node: AVAudioNode
    public let bus: AVAudioNodeBus
    public init(_ node: AVAudioNode, bus: AVAudioNodeBus = 0) { self.node = node; self.bus = bus }
}

@MainActor
open class AudioProcessor {
    public let model: MixerNode
    public let nodes: [AVAudioNode]
    public let inputs: [String: AudioEndpoint]
    public let outputs: [String: AudioEndpoint]
    public let connections: [(source: AudioEndpoint, destination: AudioEndpoint)]
    private let bypassUnits: [AVAudioUnitEffect]

    public init(model: MixerNode, nodes: [AVAudioNode], inputs: [String: AudioEndpoint],
                outputs: [String: AudioEndpoint], bypassUnits: [AVAudioUnitEffect] = [],
                connections: [(source: AudioEndpoint, destination: AudioEndpoint)] = []) {
        self.connections = connections
        self.model = model
        self.nodes = nodes
        self.inputs = inputs
        self.outputs = outputs
        self.bypassUnits = bypassUnits
    }

    public final func apply(inheritedBypass: Bool = false) {
        let bypassed = inheritedBypass || model.isBypassed
        applyParameters(bypassed: bypassed)
        for unit in bypassUnits { unit.bypass = bypassed }
    }

    open func applyParameters(bypassed: Bool) {}
}

public enum AudioGraphError: Error, Equatable {
    case engineRunning
    case duplicateRegistration(String)
    case unregisteredType(String)
    case incompatibleProcessor(String)
    case unsupportedPort(PortAddress)
    case missingOutput(PortAddress)
}

@MainActor
public final class AudioProcessorRegistry {
    public typealias Factory = @MainActor (MixerNode) throws -> AudioProcessor
    private var factories: [String: Factory] = [:]
    public init() {}

    public func register<Node: MixerNode>(_ typeID: String, nodeType: Node.Type,
                                         factory: @escaping @MainActor (Node) throws -> AudioProcessor) throws {
        guard factories[typeID] == nil else { throw AudioGraphError.duplicateRegistration(typeID) }
        factories[typeID] = { node in
            guard let typed = node as? Node else { throw AudioGraphError.incompatibleProcessor(node.id) }
            return try factory(typed)
        }
    }

    func make(_ node: MixerNode) throws -> AudioProcessor {
        guard let factory = factories[node.typeID] else { throw AudioGraphError.unregisteredType(node.typeID) }
        let processor = try factory(node)
        let identities = Set(processor.nodes.map(ObjectIdentifier.init))
        let endpoints = Array(processor.inputs.values) + Array(processor.outputs.values)
            + processor.connections.flatMap { [$0.source, $0.destination] }
        guard processor.model === node, identities.count == processor.nodes.count,
              endpoints.allSatisfy({ identities.contains(ObjectIdentifier($0.node)) }),
              processor.connections.allSatisfy({ edge in
                  edge.source.bus < edge.source.node.numberOfOutputs
                      && (edge.destination.node is AVAudioMixerNode || edge.destination.bus < edge.destination.node.numberOfInputs)
              }),
              processor.nodes.allSatisfy({ $0.engine == nil }),
              processor.inputs.values.allSatisfy({ $0.node is AVAudioMixerNode || $0.bus < $0.node.numberOfInputs }),
              processor.outputs.values.allSatisfy({ $0.bus < $0.node.numberOfOutputs }),
              Set(processor.inputs.keys) == Set(node.ports.filter { $0.direction == .input }.map(\.id)),
              Set(processor.outputs.keys) == Set(node.ports.filter { $0.direction == .output }.map(\.id)) else {
            throw AudioGraphError.incompatibleProcessor(node.id)
        }
        return processor
    }
}
