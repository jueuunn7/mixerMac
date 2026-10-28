import MixerCore

public enum StandardNodeRegistry {
    @MainActor
    public static func make() throws -> NodeRegistry {
        let registry = NodeRegistry()
        try register(in: registry)
        return registry
    }

    @MainActor
    public static func register(in registry: NodeRegistry) throws {
        let definitions: [(String, NodeRegistry.Factory)] = [
            ("core.chain", { ProcessingChain(id: $0.id) }),
            ("core.channel", { Channel(id: $0.id) }),
            ("core.bus", { MixBus(id: $0.id) }),
            (StandardNodeType.gain, { GainNode(id: $0.id) }),
            (StandardNodeType.volume, { VolumeNode(id: $0.id) }),
            (StandardNodeType.pan, { PanNode(id: $0.id) }),
            (StandardNodeType.width, { WidthNode(id: $0.id) }),
            (StandardNodeType.parametricEQ, { ParametricEQNode(id: $0.id) }),
            ("standard.equalizer", { Equalizer(id: $0.id) }),
            ("standard.console-bus", { ConsoleBus(id: $0.id) })
        ]
        for (typeID, factory) in definitions {
            try registry.register(typeID) { snapshot in
                guard snapshot.configurationVersion == 1, snapshot.configuration.isEmpty else {
                    throw SnapshotError.incompatibleNode(snapshot.id)
                }
                return try factory(snapshot)
            }
        }
        try registry.register("standard.console-channel", migrate: migrateChannel) { snapshot in
            guard snapshot.configurationVersion == 2, snapshot.configuration.isEmpty else {
                throw SnapshotError.incompatibleNode(snapshot.id)
            }
            return ConsoleChannel(id: snapshot.id)
        }
    }

    @MainActor
    private static func migrateChannel(_ snapshot: NodeSnapshot) throws -> NodeSnapshot {
        guard snapshot.configurationVersion == 1 else { return snapshot }
        var children = snapshot.children
        if !children.contains(where: { $0.id == snapshot.id + ".width" }) {
            let position = children.firstIndex(where: { $0.id == snapshot.id + ".pan" }) ?? children.count
            children.insert(try NodeSnapshot(WidthNode(id: snapshot.id + ".width")), at: position)
        }
        return NodeSnapshot(id: snapshot.id, typeID: snapshot.typeID, structure: snapshot.structure,
            configurationVersion: 2, configuration: snapshot.configuration, ports: snapshot.ports,
            parameters: snapshot.parameters, isBypassed: snapshot.isBypassed, children: children)
    }
}
