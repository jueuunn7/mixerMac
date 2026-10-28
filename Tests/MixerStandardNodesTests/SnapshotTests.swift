import Foundation
import MixerCore
import MixerStandardNodes
import Testing

struct SnapshotTests {
    @Test @MainActor func standardPresetRoundTripRetainsTypedParameterIdentityAndAddedNodes() throws {
        let channel = ConsoleChannel(id: "app")
        channel.equalizer.bands[5].gain.setValue(4)
        try channel.append(GainNode(id: "extra", value: -3))
        let registry = try StandardNodeRegistry.make()
        let snapshot = try JSONDecoder().decode(NodeSnapshot.self, from: JSONEncoder().encode(NodeSnapshot(channel)))
        let restored = try #require(try registry.makeNode(from: snapshot) as? ConsoleChannel)
        #expect(restored.settings == channel.settings)
        #expect(restored.children.first === restored.equalizer)
        #expect(restored.children.last?.parameters["gain"]?.value == -3)
        #expect(try NodeSnapshot(restored) == snapshot)
    }

    @Test @MainActor func graphRoundTripRetainsCustomRoutingAndInvalidRestoreIsAtomic() throws {
        let mixer = ConsoleMixer(channels: [ConsoleChannel(id: "one"), ConsoleChannel(id: "two")])
        let bus = MixBus(id: "submix", nodes: [GainNode(id: "submix.gain", value: -6)])
        try mixer.graph.add(bus)
        let first = try #require(mixer.graph.connections.first)
        try mixer.graph.disconnect(first)
        try mixer.graph.connect(first.source, to: PortAddress(nodeID: bus.id, portID: "input"))
        try mixer.graph.connect(PortAddress(nodeID: bus.id, portID: "output"), to: first.destination)
        let snapshot = try GraphSnapshot(mixer.graph)
        let graph = AudioGraph()
        let registry = try StandardNodeRegistry.make()
        try registry.restore(snapshot, into: graph)
        #expect(try GraphSnapshot(graph) == snapshot)
        let revision = graph.revision
        let emptyRegistry = NodeRegistry()
        #expect(throws: SnapshotError.self) { try emptyRegistry.restore(snapshot, into: graph) }
        #expect(graph.revision == revision)
        #expect(try GraphSnapshot(graph) == snapshot)
    }
}

extension SnapshotTests {
    @Test @MainActor func invalidStoredIdentifierIsRejectedBeforeTheFactoryIsCalled() throws {
        let original = try JSONEncoder().encode(NodeSnapshot(ConsoleChannel(id: "valid")))
        var data = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        data["id"] = ""
        let snapshot = try JSONDecoder().decode(NodeSnapshot.self, from: JSONSerialization.data(withJSONObject: data))
        let registry = try StandardNodeRegistry.make()
        #expect(throws: SnapshotError.incompatibleNode("")) { try registry.makeNode(from: snapshot) }
    }
}
