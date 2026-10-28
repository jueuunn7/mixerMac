import MixerCore

public enum ConsoleDocumentMigration {
    public static func removingBuiltInEffects(from snapshot: GraphSnapshot) -> GraphSnapshot {
        let returnTypes = ["console.fx.reverb": "standard.reverb-return", "console.fx.delay": "standard.delay-return"]
        let removed = Set(snapshot.nodes.filter { node in
            returnTypes[node.id] == node.typeID || (node.typeID == "standard.send"
                && returnTypes.keys.contains { node.id.hasSuffix(".send." + $0) })
        }.map(\.id))
        guard !removed.isEmpty else { return snapshot }
        return GraphSnapshot(version: snapshot.version, nodes: snapshot.nodes.filter { !removed.contains($0.id) },
            connections: snapshot.connections.filter { !removed.contains($0.source.nodeID) && !removed.contains($0.destination.nodeID) })
    }
}
