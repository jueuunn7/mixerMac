import MixerCore

@MainActor
public final class ConsoleFilters {
    public let banks: [ConsoleFilterBank]
    private let mixer: ConsoleMixer

    public init(mixer: ConsoleMixer) throws {
        self.mixer = mixer
        banks = try (1...2).map { index in
            let id = "console.filter\(index)"
            if let node = mixer.graph.nodes.first(where: { $0.id == id }) {
                guard let bank = node as? ConsoleFilterBank else { throw SnapshotError.incompatibleNode(id) }
                return bank
            }
            return ConsoleFilterBank(id: id)
        }
        try connectChannels()
    }

    public func router(channelID: String) -> FilterRouterNode? {
        mixer.graph.nodes.first { $0.id == channelID + ".filter-route" } as? FilterRouterNode
    }

    public func connectChannels() throws {
        var nodes = mixer.graph.nodes
        var connections = mixer.graph.connections
        let channelIDs = Set(mixer.channels.map(\.id))
        let staleRouters = Set(nodes.compactMap { node -> String? in
            guard node.id.hasSuffix(".filter-route") else { return nil }
            let channelID = String(node.id.dropLast(".filter-route".count))
            return channelIDs.contains(channelID) ? nil : node.id
        })
        if !staleRouters.isEmpty {
            nodes.removeAll { staleRouters.contains($0.id) }
            connections.removeAll { staleRouters.contains($0.source.nodeID) || staleRouters.contains($0.destination.nodeID) }
        }
        for bank in banks where !nodes.contains(where: { $0 === bank }) {
            nodes.append(bank)
            connections.append(AudioConnection(source: PortAddress(nodeID: bank.id, portID: "output"),
                destination: PortAddress(nodeID: mixer.master.id, portID: "input")))
        }
        for channel in mixer.channels {
            let id = channel.id + ".filter-route"
            if let existing = nodes.first(where: { $0.id == id }) {
                guard existing is FilterRouterNode else { throw SnapshotError.incompatibleNode(id) }
                continue
            }
            let dry = AudioConnection(source: PortAddress(nodeID: channel.id, portID: "output"),
                destination: PortAddress(nodeID: mixer.master.id, portID: "input"))
            // Custom routes remain untouched; only the console's direct-to-master route is assigned.
            guard connections.contains(dry) else { continue }
            connections.removeAll { $0 == dry }
            nodes.append(FilterRouterNode(id: id))
            connections.append(AudioConnection(source: dry.source, destination: PortAddress(nodeID: id, portID: "input")))
            connections.append(AudioConnection(source: PortAddress(nodeID: id, portID: "dry"), destination: dry.destination))
            for (index, bank) in banks.enumerated() {
                connections.append(AudioConnection(source: PortAddress(nodeID: id, portID: "filter\(index + 1)"),
                    destination: PortAddress(nodeID: bank.id, portID: "input")))
            }
        }
        try mixer.graph.replace(nodes: nodes, connections: connections)
    }
}
