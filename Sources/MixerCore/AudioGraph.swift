import Combine

public struct PortAddress: Hashable, Codable, Sendable {
    public let nodeID: String
    public let portID: String
    public init(nodeID: String, portID: String) { self.nodeID = nodeID; self.portID = portID }
}

public struct AudioConnection: Hashable, Codable, Sendable {
    public let source: PortAddress
    public let destination: PortAddress
    public init(source: PortAddress, destination: PortAddress) { self.source = source; self.destination = destination }
}

public enum GraphError: Error, Equatable {
    case duplicateNode(String)
    case missingNode(String)
    case missingPort(PortAddress)
    case invalidDirection
    case incompatiblePorts
    case cycle
    case nodeAlreadyOwned(String)
    case duplicateConnection(AudioConnection)
}

public enum GraphChange: Equatable, Sendable { case topology, node(String) }

@MainActor
public final class AudioGraph {
    public private(set) var nodes: [MixerNode] = []
    public private(set) var connections: [AudioConnection] = []
    public private(set) var revision: UInt64 = 0
    public private(set) var topologyRevision: UInt64 = 0
    private let changed = PassthroughSubject<GraphChange, Never>()
    public var changes: AnyPublisher<GraphChange, Never> { changed.eraseToAnyPublisher() }
    private var subscriptions: [AnyCancellable] = []

    public init() {}

    public func add(_ node: MixerNode) throws { try replace(nodes: nodes + [node], connections: connections) }

    public func remove(id: String) throws {
        try replace(nodes: nodes.filter { $0.id != id },
            connections: connections.filter { $0.source.nodeID != id && $0.destination.nodeID != id })
    }

    public func connect(_ source: PortAddress, to destination: PortAddress) throws {
        let connection = AudioConnection(source: source, destination: destination)
        guard !connections.contains(connection) else { return }
        try replace(nodes: nodes, connections: connections + [connection])
    }

    public func disconnect(_ connection: AudioConnection) throws {
        try replace(nodes: nodes, connections: connections.filter { $0 != connection })
    }

    public func replace(nodes: [MixerNode], connections: [AudioConnection]) throws {
        try Self.validateNodeTree(nodes, owner: self)
        var seen: Set<AudioConnection> = []
        for connection in connections {
            guard seen.insert(connection).inserted else { throw GraphError.duplicateConnection(connection) }
            let source = try Self.port(connection.source, nodes: nodes)
            let destination = try Self.port(connection.destination, nodes: nodes)
            guard source.direction == .output, destination.direction == .input else { throw GraphError.invalidDirection }
            guard source.channels == destination.channels, source.signal == destination.signal else { throw GraphError.incompatiblePorts }
        }
        _ = try Self.ordered(nodes: nodes, connections: connections)
        if self.connections == connections && self.nodes.count == nodes.count
            && zip(self.nodes, nodes).allSatisfy({ $0 === $1 }) { return }
        updateOwnership(removing: self.nodes, adding: nodes)
        self.nodes = nodes
        self.connections = connections
        subscriptions = nodes.map { node in
            node.changes.sink { [weak self, id = node.id] change in
                self?.publishChange(change == .structure ? .topology : .node(id))
            }
        }
        publishChange(.topology)
    }

    public func processingOrder() throws -> [MixerNode] { try Self.ordered(nodes: nodes, connections: connections) }

    static func validateNodeTree(_ nodes: [MixerNode], excluding: Set<String> = [], owner: AudioGraph? = nil,
                                 substitutions: [String: [MixerNode]] = [:]) throws {
        var seen = excluding
        func visit(_ node: MixerNode) throws {
            guard seen.insert(node.id).inserted else { throw GraphError.duplicateNode(node.id) }
            if let current = node.ownerGraph, current !== owner { throw GraphError.nodeAlreadyOwned(node.id) }
            for child in substitutions[node.id] ?? node.children { try visit(child) }
        }
        for node in nodes { try visit(node) }
    }

    func validateReplacement(of node: MixerNode, children: [MixerNode]) throws {
        try Self.validateNodeTree(nodes, owner: self, substitutions: [node.id: children])
    }

    func updateOwnership(removing: [MixerNode], adding: [MixerNode]) {
        func assign(_ node: MixerNode, owner: AudioGraph?) {
            node.ownerGraph = owner
            for child in node.children { assign(child, owner: owner) }
        }
        for node in removing { assign(node, owner: nil) }
        for node in adding { assign(node, owner: self) }
    }

    private static func port(_ address: PortAddress, nodes: [MixerNode]) throws -> AudioPort {
        guard let node = nodes.first(where: { $0.id == address.nodeID }) else { throw GraphError.missingNode(address.nodeID) }
        guard let port = node.ports.first(where: { $0.id == address.portID }) else { throw GraphError.missingPort(address) }
        return port
    }

    private static func ordered(nodes: [MixerNode], connections: [AudioConnection]) throws -> [MixerNode] {
        var remaining = nodes
        var edges = connections
        var result: [MixerNode] = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { node in !edges.contains { $0.destination.nodeID == node.id } }) else {
                throw GraphError.cycle
            }
            let node = remaining.remove(at: index)
            result.append(node)
            edges.removeAll { $0.source.nodeID == node.id }
        }
        return result
    }

    private func publishChange(_ change: GraphChange) {
        revision &+= 1
        if change == .topology { topologyRevision &+= 1 }
        changed.send(change)
    }
}
