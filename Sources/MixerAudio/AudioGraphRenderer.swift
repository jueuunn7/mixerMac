import MixerCore
@preconcurrency import AVFAudio

@MainActor
public final class AudioGraphRenderer {
    private struct Connection { let source: AudioEndpoint; let destination: AudioEndpoint }
    private struct RuntimeNode {
        let inputs: [String: AudioEndpoint]
        let outputs: [String: AudioEndpoint]
    }
    private struct BuildRequest {
        let graph: AudioGraph
        let output: PortAddress
        let externalInputs: [PortAddress: AudioEndpoint]
        let feeds: [PortAddress: PCMFeed]
    }
    public let engine: AVAudioEngine
    public let format: AVAudioFormat
    private let registry: AudioProcessorRegistry
    private var processors: [(AudioProcessor, [MixerNode])] = []
    private var channelGates: [(Channel, AVAudioMixerNode)] = []
    private var attached: [AVAudioNode] = []
    private var connections: [Connection] = []
    private var topologyRevision: UInt64?
    private var taps: [AudioEndpoint] = []
    private var activeNodeIDs: Set<String> = []
    private var nodeOutputs: [PortAddress: AudioEndpoint] = [:]
    private var graphIdentity: ObjectIdentifier?
    private var lastBuild: BuildRequest?

    public init(engine: AVAudioEngine, format: AVAudioFormat, registry: AudioProcessorRegistry) {
        self.engine = engine
        self.format = format
        self.registry = registry
    }

    public func rebuild(_ graph: AudioGraph, output: PortAddress,
                        externalInputs: [PortAddress: AudioEndpoint] = [:], feeds: [PortAddress: PCMFeed] = [:]) throws {
        guard !engine.isRunning else { throw AudioGraphError.engineRunning }
        let request = BuildRequest(graph: graph, output: output, externalInputs: externalInputs, feeds: feeds)
        let previous = lastBuild
        do {
            try rebuildOnce(request)
            lastBuild = request
        } catch {
            clearRuntime()
            do {
                if let previous {
                    try rebuildOnce(previous)
                    lastBuild = previous
                } else {
                    lastBuild = nil
                }
            } catch {
                clearRuntime()
                lastBuild = nil
            }
            throw error
        }
    }

    private func rebuildOnce(_ request: BuildRequest) throws {
        let graph = request.graph
        let output = request.output
        let externalInputs = request.externalInputs
        let feeds = request.feeds
        // Build and validate every adapter before touching the running engine.
        var definitions: [String: AudioProcessor] = [:]
        var nativeIDs: Set<ObjectIdentifier> = []
        func prepare(_ node: MixerNode) throws {
            for port in node.ports where port.channels != 2 || port.signal != "audio.float32" {
                throw AudioGraphError.unsupportedPort(PortAddress(nodeID: node.id, portID: port.id))
            }
            if node.structure == .serial {
                guard node.ports == [.stereoInput, .stereoOutput] else {
                    throw AudioGraphError.incompatibleProcessor(node.id)
                }
                for child in node.children {
                    guard child.ports == [.stereoInput, .stereoOutput] else {
                        throw AudioGraphError.incompatibleProcessor(child.id)
                    }
                    try prepare(child)
                }
            } else {
                let processor = try registry.make(node)
                for native in processor.nodes {
                    guard nativeIDs.insert(ObjectIdentifier(native)).inserted else {
                        throw AudioGraphError.incompatibleProcessor(node.id)
                    }
                }
                definitions[node.id] = processor
            }
        }
        for node in graph.nodes { try prepare(node) }
        let order = try graph.processingOrder()
        func hasOutput(_ nodes: [MixerNode]) -> Bool {
            nodes.contains { node in
                (node.id == output.nodeID && node.ports.contains { $0.id == output.portID && $0.direction == .output })
                    || hasOutput(node.children)
            }
        }
        guard hasOutput(graph.nodes) else { throw AudioGraphError.missingOutput(output) }
        for address in externalInputs.keys {
            guard let node = graph.nodes.first(where: { $0.id == address.nodeID }),
                  node.ports.contains(where: { $0.id == address.portID && $0.direction == .input }) else {
                throw AudioGraphError.unsupportedPort(address)
            }
        }
        clearRuntime()
        var roots: [String: RuntimeNode] = [:]
        for node in order { roots[node.id] = build(node, ancestors: [], definitions: definitions) }
        for edge in graph.connections {
            connections.append(Connection(source: roots[edge.source.nodeID]!.outputs[edge.source.portID]!,
                destination: roots[edge.destination.nodeID]!.inputs[edge.destination.portID]!))
        }
        for (address, source) in externalInputs {
            connections.append(Connection(source: source, destination: roots[address.nodeID]!.inputs[address.portID]!))
        }
        connections.append(Connection(source: nodeOutputs[output]!,
            destination: AudioEndpoint(engine.mainMixerNode)))
        var reachable = Set(externalInputs.keys.map(\.nodeID))
        reachable.formUnion(graph.nodes.filter { !$0.ports.contains { $0.direction == .input } }.map(\.id))
        for node in order {
            if graph.connections.contains(where: { $0.destination.nodeID == node.id && reachable.contains($0.source.nodeID) }) {
                reachable.insert(node.id)
            }
        }
        func includeChildren(_ node: MixerNode) {
            activeNodeIDs.insert(node.id)
            for child in node.children { includeChildren(child) }
        }
        for node in graph.nodes where reachable.contains(node.id) { includeChildren(node) }
        connectAll()
        for (address, feed) in feeds {
            guard let endpoint = nodeOutputs[address] else { continue }
            endpoint.node.installTap(onBus: endpoint.bus, bufferSize: 1024, format: nil) { buffer, _ in feed.push(buffer) }
            taps.append(endpoint)
        }
        topologyRevision = graph.topologyRevision
        graphIdentity = ObjectIdentifier(graph)
        apply()
    }

    public func isCurrent(for graph: AudioGraph) -> Bool {
        graphIdentity == ObjectIdentifier(graph) && topologyRevision == graph.topologyRevision
    }

    public func apply() {
        for (processor, ancestors) in processors {
            processor.apply(inheritedBypass: ancestors.contains { $0.isBypassed })
        }
        let audible = Channel.audibleIDs(in: channelGates.map { $0.0 }, activeIDs: activeNodeIDs)
        for (channel, gate) in channelGates {
            gate.outputVolume = audible.contains(channel.id) ? 1 : 0
        }
    }

    public func detach() {
        clearRuntime()
        lastBuild = nil
    }

    private func clearRuntime() {
        for tap in taps { tap.node.removeTap(onBus: tap.bus) }
        taps.removeAll()
        for node in attached {
            engine.disconnectNodeInput(node)
            engine.disconnectNodeOutput(node)
        }
        for node in attached { engine.detach(node) }
        activeNodeIDs.removeAll()
        nodeOutputs.removeAll()
        attached.removeAll()
        processors.removeAll()
        channelGates.removeAll()
        connections.removeAll()
        topologyRevision = nil
        graphIdentity = nil
    }

    private func attach(_ node: AVAudioNode) {
        engine.attach(node)
        attached.append(node)
    }

    private func build(_ node: MixerNode, ancestors: [MixerNode], definitions: [String: AudioProcessor]) -> RuntimeNode {
        let runtime: RuntimeNode
        if node.structure == .serial {
            let entry = AVAudioMixerNode()
            let exit = AVAudioMixerNode()
            attach(entry); attach(exit)
            var previous = AudioEndpoint(entry)
            for child in node.children {
                let runtime = build(child, ancestors: ancestors + [node], definitions: definitions)
                connections.append(Connection(source: previous, destination: runtime.inputs["input"]!))
                previous = runtime.outputs["output"]!
            }
            connections.append(Connection(source: previous, destination: AudioEndpoint(exit)))
            if let channel = node as? Channel { channelGates.append((channel, exit)) }
            runtime = RuntimeNode(inputs: ["input": AudioEndpoint(entry)], outputs: ["output": AudioEndpoint(exit)])
        } else {
            let processor = definitions[node.id]!
            for audioNode in processor.nodes { attach(audioNode) }
            connections.append(contentsOf: processor.connections.map { Connection(source: $0.source, destination: $0.destination) })
            var inputs: [String: AudioEndpoint] = [:]
            for (id, input) in processor.inputs {
                let sum = AVAudioMixerNode()
                attach(sum)
                connections.append(Connection(source: AudioEndpoint(sum), destination: input))
                inputs[id] = AudioEndpoint(sum)
            }
            processors.append((processor, ancestors))
            runtime = RuntimeNode(inputs: inputs, outputs: processor.outputs)
        }
        for (id, endpoint) in runtime.outputs { nodeOutputs[PortAddress(nodeID: node.id, portID: id)] = endpoint }
        return runtime
    }

    private func connectAll() {
        struct OutputKey: Hashable { let node: ObjectIdentifier; let bus: AVAudioNodeBus }
        var destinations: [OutputKey: [AVAudioConnectionPoint]] = [:]
        var sources: [OutputKey: AudioEndpoint] = [:]
        var mixerBus: [ObjectIdentifier: AVAudioNodeBus] = [:]
        for connection in connections {
            let source = connection.source
            let destination = connection.destination
            var bus = destination.bus
            if destination.node is AVAudioMixerNode {
                let id = ObjectIdentifier(destination.node)
                bus = mixerBus[id, default: 0]
                mixerBus[id] = bus + 1
            }
            let key = OutputKey(node: ObjectIdentifier(source.node), bus: source.bus)
            sources[key] = source
            destinations[key, default: []].append(AVAudioConnectionPoint(node: destination.node, bus: bus))
        }
        for (key, points) in destinations {
            let source = sources[key]!
            let connectionFormat = source.node is AVAudioSourceNode ? source.node.outputFormat(forBus: source.bus) : format
            engine.connect(source.node, to: points, fromBus: source.bus, format: connectionFormat)
        }
    }
}
