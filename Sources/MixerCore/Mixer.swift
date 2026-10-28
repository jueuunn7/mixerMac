import Combine

public enum MixerChange: Equatable, Sendable {
    case channels
    case channel(String)
    case master
    case routing
}

@MainActor
public final class Mixer<Master: MixBus> {
    public var channels: [Channel] { graph.nodes.compactMap { $0 as? Channel } }
    public let master: Master
    public let graph = AudioGraph()
    private let changed = PassthroughSubject<MixerChange, Never>()
    public var changes: AnyPublisher<MixerChange, Never> { changed.eraseToAnyPublisher() }
    private var subscription: AnyCancellable?
    private var replacingChannels = false

    public init(master: Master, channels: [Channel] = []) {
        self.master = master
        subscription = graph.changes.sink { [weak self] change in
            guard let self, !self.replacingChannels else { return }
            switch change {
            case .topology: self.changed.send(.routing)
            case .node(let id):
                if id == self.master.id { self.changed.send(.master) }
                else if self.channels.contains(where: { $0.id == id }) { self.changed.send(.channel(id)) }
                else { self.changed.send(.routing) }
            }
        }
        replaceChannels(channels)
    }

    public func addChannel(_ channel: Channel) { replaceChannels(channels + [channel]) }
    public func removeChannel(id: String) { replaceChannels(channels.filter { $0.id != id }) }

    public func replaceChannels(_ channels: [Channel]) {
        precondition(Set(channels.map(\.id)).count == channels.count, "Channel IDs must be unique")
        if graph.nodes.contains(where: { $0 === master }) && self.channels.count == channels.count
            && zip(self.channels, channels).allSatisfy({ $0 === $1 }) { return }
        let previousIDs = Set(self.channels.map(\.id))
        let removed = previousIDs.subtracting(channels.map(\.id))
        let otherNodes = graph.nodes.filter { !previousIDs.contains($0.id) && $0 !== master }
        var connections = graph.connections.filter { !removed.contains($0.source.nodeID) && !removed.contains($0.destination.nodeID) }
        for channel in channels where !previousIDs.contains(channel.id) {
            connections.append(AudioConnection(source: PortAddress(nodeID: channel.id, portID: "output"),
                destination: PortAddress(nodeID: master.id, portID: "input")))
        }
        replacingChannels = true
        defer { replacingChannels = false }
        do { try graph.replace(nodes: otherNodes + channels + [master], connections: connections) }
        catch { preconditionFailure("Invalid mixer membership: \(error)") }
        changed.send(.channels)
    }

    public var audibleChannelIDs: Set<String> {
        Channel.audibleIDs(in: channels)
    }
}
