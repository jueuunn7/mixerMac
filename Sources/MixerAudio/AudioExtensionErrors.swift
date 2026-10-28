import Foundation

extension AudioGraphError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .engineRunning: "Stop the output before rebuilding its audio graph"
        case .duplicateRegistration(let type): "Audio processor is already registered: \(type)"
        case .unregisteredType(let type): "Unavailable audio processor: \(type)"
        case .incompatibleProcessor(let id): "Audio processor does not match its node: \(id)"
        case .unsupportedPort(let port): "Unsupported audio port: \(port.nodeID).\(port.portID)"
        case .missingOutput(let port): "Missing mixer output: \(port.nodeID).\(port.portID)"
        }
    }
}

extension AudioSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidState: "The audio source is not ready for this operation"
        case .unimplemented: "The audio source has no resource implementation"
        case .duplicateRegistration(let type): "Audio source is already registered: \(type)"
        case .unregisteredType(let type): "Unavailable audio source: \(type)"
        case .incompatibleSource(let id): "Audio source does not match its definition: \(id)"
        }
    }
}
