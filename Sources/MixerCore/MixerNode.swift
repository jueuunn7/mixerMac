import Combine
import Foundation

public enum NodeChange: Equatable, Sendable { case parameters, structure }

public struct AudioPort: Hashable, Codable, Sendable {
    public enum Direction: String, Codable, Sendable { case input, output }
    public let id: String
    public let direction: Direction
    public let channels: Int
    public let signal: String

    public init(id: String, direction: Direction, channels: Int = 2, signal: String = "audio.float32") {
        precondition(!id.isEmpty && channels > 0 && !signal.isEmpty)
        self.id = id
        self.direction = direction
        self.channels = channels
        self.signal = signal
    }

    public static let stereoInput = Self(id: "input", direction: .input)
    public static let stereoOutput = Self(id: "output", direction: .output)
}

@MainActor
open class MixerNode: Identifiable {
    public enum Structure: String, Codable, Sendable { case processor, serial }
    public nonisolated let id: String
    public let typeID: String
    public let ports: [AudioPort]
    public let parameters: [String: Parameter]
    public let structure: Structure
    public final private(set) var isBypassed = false
    public final private(set) var revision: UInt64 = 0
    public final private(set) var children: [MixerNode]
    weak var ownerGraph: AudioGraph?
    private let changed = PassthroughSubject<NodeChange, Never>()
    public final var changes: AnyPublisher<NodeChange, Never> { changed.eraseToAnyPublisher() }
    private var parameterSubscriptions: [AnyCancellable] = []
    private var childSubscriptions: [AnyCancellable] = []
    private var updateDepth = 0
    private var pendingChange: NodeChange?

    public init(id: String, typeID: String, ports: [AudioPort], parameters: [String: Parameter] = [:],
                structure: Structure = .processor, children: [MixerNode] = []) {
        precondition(!id.isEmpty && !typeID.isEmpty)
        precondition(Set(ports.map(\.id)).count == ports.count)
        precondition(structure == .serial || children.isEmpty)
        self.id = id
        self.typeID = typeID
        self.ports = ports
        self.parameters = parameters
        self.structure = structure
        self.children = children
        parameterSubscriptions = parameters.values.map { parameter in
            parameter.changes.sink { [weak self] in self?.recordChange(.parameters) }
        }
        observeChildren()
    }

    open var configurationVersion: Int { 1 }
    open func encodeConfiguration() throws -> Data { Data() }
    open func validateConfiguration(version: Int, data: Data) throws {
        guard version == configurationVersion, data.isEmpty else { throw SnapshotError.incompatibleNode(id) }
    }

    public final func setBypassed(_ bypassed: Bool) {
        guard isBypassed != bypassed else { return }
        isBypassed = bypassed
        recordChange(.parameters)
    }

    public final func performUpdate(_ update: () throws -> Void) rethrows {
        updateDepth += 1
        defer {
            updateDepth -= 1
            if updateDepth == 0, let change = pendingChange {
                pendingChange = nil
                publishChange(change)
            }
        }
        try update()
    }

    public final func resetParameters() {
        performUpdate {
            for parameter in parameters.values { parameter.reset() }
            for child in children { child.resetParameters() }
        }
    }

    final func replaceChildren(_ children: [MixerNode]) {
        if self.children.count == children.count && zip(self.children, children).allSatisfy({ $0 === $1 }) { return }
        let previous = self.children
        self.children = children
        ownerGraph?.updateOwnership(removing: previous, adding: children)
        observeChildren()
        recordChange(.structure)
    }

    private func observeChildren() {
        childSubscriptions = children.map { child in
            child.changes.sink { [weak self] change in self?.recordChange(change) }
        }
    }

    private func recordChange(_ change: NodeChange) {
        if updateDepth > 0 {
            if pendingChange != .structure { pendingChange = change }
        } else { publishChange(change) }
    }

    private func publishChange(_ change: NodeChange) {
        revision &+= 1
        changed.send(change)
    }
}

@MainActor
open class ProcessingChain: MixerNode {
    public init(id: String, typeID: String = "core.chain", nodes: [MixerNode] = [], parameters: [String: Parameter] = [:]) {
        super.init(id: id, typeID: typeID, ports: [.stereoInput, .stereoOutput], parameters: parameters,
            structure: .serial, children: nodes)
    }

    public final func setProcessingNodes(_ nodes: [MixerNode]) throws {
        try validateProcessingNodes(nodes)
        if let ownerGraph { try ownerGraph.validateReplacement(of: self, children: nodes) }
        else { try AudioGraph.validateNodeTree(nodes, excluding: [id]) }
        replaceChildren(nodes)
    }

    public final func append(_ node: MixerNode) throws { try setProcessingNodes(children + [node]) }

    public final func remove(id: String) throws { try setProcessingNodes(children.filter { $0.id != id }) }

    open func validateProcessingNodes(_ nodes: [MixerNode]) throws {}
}
