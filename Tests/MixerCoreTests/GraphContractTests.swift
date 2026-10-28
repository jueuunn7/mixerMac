import Combine
import MixerCore
import MixerExtensionFixtures
import Testing

struct GraphContractTests {
    @Test @MainActor func steppedDefaultsAndInvalidInputsUseTheSameInheritedPolicy() {
        let control = Parameter(value: .nan, range: 0...1, defaultValue: 0.6, unit: .ratio, step: 0.5)
        #expect(control.defaultValue == 0.5)
        #expect(control.value == 0.5)
        control.setValue(1)
        control.reset()
        #expect(control.value == 0.5)
        control.setValue(.infinity)
        #expect(control.value == 0.5)
    }

    private func output(_ id: String) -> PortAddress { PortAddress(nodeID: id, portID: "output") }
    private func input(_ id: String) -> PortAddress { PortAddress(nodeID: id, portID: "input") }

    @Test @MainActor func externalSubclassInheritsNormalizationAndResetPolicy() {
        let threshold = ExternalThreshold()
        threshold.setValue(-11.74)
        #expect(threshold.value == -11.5)
        threshold.setValue(-100)
        #expect(threshold.value == -60)
        threshold.setValue(.nan)
        #expect(threshold.value == -12)
        threshold.setValue(0)
        threshold.reset()
        #expect(threshold.value == -12)
        let customUnit = Parameter.Unit(rawValue: "vendor.custom-unit")
        #expect(customUnit.rawValue == "vendor.custom-unit")
    }

    @Test @MainActor func inheritedBatchingAndResetReachNestedExternalNodes() {
        let first = ExternalGain(id: "first")
        let second = ExternalGain(id: "second")
        let chain = ProcessingChain(id: "chain", nodes: [first, second])
        var snapshots: [[Float]] = []
        let subscription = chain.changes.sink { _ in snapshots.append([first.amount.value, second.amount.value]) }
        chain.performUpdate {
            first.amount.setValue(2)
            chain.performUpdate { second.amount.setValue(3) }
        }
        #expect(snapshots == [[2, 3]])
        #expect(chain.revision == 1)
        chain.resetParameters()
        #expect(snapshots == [[2, 3], [1, 1]])
        #expect(chain.revision == 2)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func graphAcceptsNewTypesAndOrdersFanInAndFanOut() throws {
        let graph = AudioGraph()
        let first = ExternalInput(id: "first")
        let second = ExternalInput(id: "second")
        let gain = ExternalGain(id: "gain")
        let main = ExternalOutput(id: "main")
        let monitor = ExternalOutput(id: "monitor")
        try graph.replace(nodes: [main, monitor, gain, first, second], connections: [
            AudioConnection(source: output("first"), destination: input("gain")),
            AudioConnection(source: output("second"), destination: input("gain")),
            AudioConnection(source: output("gain"), destination: input("main")),
            AudioConnection(source: output("gain"), destination: input("monitor"))
        ])
        let order = try graph.processingOrder().map(\.id)
        #expect(order == ["first", "second", "gain", "main", "monitor"])
    }

    @Test @MainActor func invalidConnectionsAreRejectedWithoutPartialMutation() throws {
        let graph = AudioGraph()
        let first = ExternalGain(id: "first")
        let second = ExternalGain(id: "second")
        try graph.replace(nodes: [first, second], connections: [])
        try graph.connect(output("first"), to: input("second"))
        let previous = graph.connections
        let revision = graph.revision
        #expect(throws: GraphError.cycle) { try graph.connect(output("second"), to: input("first")) }
        #expect(throws: GraphError.invalidDirection) { try graph.connect(input("first"), to: input("second")) }
        #expect(throws: GraphError.missingNode("missing")) { try graph.connect(output("missing"), to: input("first")) }
        #expect(graph.connections == previous)
        #expect(graph.revision == revision)
    }

    @Test(arguments: [(1, "audio.float32"), (2, "vendor.other-signal")]) @MainActor
    func incompatibleFormatsCannotBeConnected(channels: Int, signal: String) throws {
        let graph = AudioGraph()
        try graph.replace(nodes: [ExternalInput(id: "source", channels: channels, signal: signal), ExternalOutput(id: "sink")], connections: [])
        #expect(throws: GraphError.incompatiblePorts) { try graph.connect(output("source"), to: input("sink")) }
        #expect(graph.connections.isEmpty)
    }

    @Test @MainActor func topologyEditsValidateNestedOwnershipAndDetachRemovedSubscriptions() throws {
        let graph = AudioGraph()
        let child = ExternalGain(id: "child")
        let chain = ProcessingChain(id: "chain", nodes: [child])
        let other = ExternalGain(id: "other")
        try graph.replace(nodes: [chain, other], connections: [])
        #expect(throws: GraphError.duplicateNode("other")) { try chain.append(ExternalGain(id: "other")) }
        #expect(chain.children.count == 1)
        let anotherGraph = AudioGraph()
        #expect(throws: GraphError.nodeAlreadyOwned("child")) { try anotherGraph.add(child) }
        try chain.remove(id: "child")
        let revision = graph.revision
        child.amount.setValue(2)
        #expect(graph.revision == revision)
        try anotherGraph.add(child)
        #expect(anotherGraph.nodes.first === child)
    }

    @Test @MainActor func controlChangesDoNotInvalidateTheCompiledTopology() throws {
        let graph = AudioGraph()
        let gain = ExternalGain(id: "gain")
        let chain = ProcessingChain(id: "chain", nodes: [gain])
        try graph.add(chain)
        let topology = graph.topologyRevision
        gain.amount.setValue(2)
        #expect(graph.topologyRevision == topology)
        try chain.append(ExternalGain(id: "new-effect"))
        #expect(graph.topologyRevision == topology + 1)
    }
}

extension GraphContractTests {
    @Test @MainActor func mixerMembershipFollowsTheOwnedGraphAndItsChannelChanges() throws {
        let mixer = Mixer(master: MixBus(id: "master"))
        let channel = Channel(id: "graph-channel")
        try mixer.graph.add(channel)
        #expect(mixer.channels.count == 1)
        #expect(mixer.channels.first === channel)
        var changes: [MixerChange] = []
        let subscription = mixer.changes.sink { changes.append($0) }
        channel.setMuted(true)
        #expect(changes == [.channel(channel.id)])
        try mixer.graph.remove(id: channel.id)
        #expect(mixer.channels.isEmpty)
        #expect(mixer.audibleChannelIDs.isEmpty)
        withExtendedLifetime(subscription) {}
    }
}
