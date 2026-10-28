import Foundation

public struct NodeSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let typeID: String
    public let structure: MixerNode.Structure
    public let configurationVersion: Int
    public let configuration: Data
    public let ports: [AudioPort]
    public let parameters: [String: Float]
    public let isBypassed: Bool
    public let children: [NodeSnapshot]

    @MainActor
    public init(_ node: MixerNode) throws {
        id = node.id
        typeID = node.typeID
        structure = node.structure
        configurationVersion = node.configurationVersion
        configuration = try node.encodeConfiguration()
        ports = node.ports
        parameters = node.parameters.mapValues(\.value)
        isBypassed = node.isBypassed
        children = try node.children.map(NodeSnapshot.init)
    }
}

public struct GraphSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let nodes: [NodeSnapshot]
    public let connections: [AudioConnection]

    @MainActor
    public init(_ graph: AudioGraph) throws {
        version = 1
        nodes = try graph.nodes.map(NodeSnapshot.init)
        connections = graph.connections
    }
}

public enum SnapshotError: Error, Equatable {
    case unsupportedVersion(Int)
    case unregisteredType(String)
    case duplicateRegistration(String)
    case incompatibleNode(String)
}

@MainActor
public final class NodeRegistry {
    public typealias Factory = @MainActor (NodeSnapshot) throws -> MixerNode
    private var factories: [String: Factory] = [:]

    public init() {}

    public func register(_ typeID: String, factory: @escaping Factory) throws {
        guard factories[typeID] == nil else { throw SnapshotError.duplicateRegistration(typeID) }
        factories[typeID] = factory
    }

    public func makeNode(from snapshot: NodeSnapshot) throws -> MixerNode {
        guard !snapshot.id.isEmpty, !snapshot.typeID.isEmpty else { throw SnapshotError.incompatibleNode(snapshot.id) }
        guard let factory = factories[snapshot.typeID] else { throw SnapshotError.unregisteredType(snapshot.typeID) }
        let node = try factory(snapshot)
        try restore(snapshot, into: node)
        return node
    }

    public func restore(_ snapshot: GraphSnapshot, into graph: AudioGraph) throws {
        guard snapshot.version == 1 else { throw SnapshotError.unsupportedVersion(snapshot.version) }
        let nodes = try snapshot.nodes.map(makeNode)
        try graph.replace(nodes: nodes, connections: snapshot.connections)
    }

    private func restore(_ snapshot: NodeSnapshot, into node: MixerNode) throws {
        guard node.id == snapshot.id, node.typeID == snapshot.typeID,
              node.ports == snapshot.ports, node.structure == snapshot.structure,
              Set(snapshot.parameters.keys).isSubset(of: Set(node.parameters.keys)),
              snapshot.parameters.values.allSatisfy(\.isFinite) else {
            throw SnapshotError.incompatibleNode(snapshot.id)
        }
        try node.validateConfiguration(version: snapshot.configurationVersion, data: snapshot.configuration)
        let children = try snapshot.children.map { child in
            if let existing = node.children.first(where: { $0.id == child.id && $0.typeID == child.typeID }) {
                try restore(child, into: existing)
                return existing
            }
            return try makeNode(from: child)
        }
        if let chain = node as? ProcessingChain { try chain.setProcessingNodes(children) }
        else if !children.isEmpty { throw SnapshotError.incompatibleNode(snapshot.id) }
        node.performUpdate {
            for (key, value) in snapshot.parameters { node.parameters[key]?.setValue(value) }
            node.setBypassed(snapshot.isBypassed)
        }
    }
}
