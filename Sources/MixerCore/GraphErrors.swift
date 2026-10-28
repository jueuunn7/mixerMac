import Foundation

extension GraphError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateNode(let id): "Duplicate node ID: \(id)"
        case .missingNode(let id): "Missing node: \(id)"
        case .missingPort(let port): "Missing port: \(port.nodeID).\(port.portID)"
        case .invalidDirection: "Audio connections must run from an output to an input"
        case .incompatiblePorts: "Connected ports have incompatible signals or channel counts"
        case .cycle: "Audio routing contains a cycle"
        case .nodeAlreadyOwned(let id): "Node already belongs to another graph: \(id)"
        case .duplicateConnection(let edge): "Duplicate connection: \(edge.source.nodeID) → \(edge.destination.nodeID)"
        }
    }
}

extension SnapshotError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported mixer document version: \(version)"
        case .unregisteredType(let type): "Unavailable mixer extension: \(type)"
        case .duplicateRegistration(let type): "Mixer extension is already registered: \(type)"
        case .incompatibleNode(let id): "Saved node does not match its registered definition: \(id)"
        }
    }
}
