import Foundation
import MixerCore
import MixerStandardNodes
import MixerAudioExtensionFixtures
@testable import MixerAudio
import Testing
@testable import mixerMac

struct GraphPersistenceIntegrationTests {
    @Test @MainActor func addedEffectsAndRoutesSurviveSessionRecreationAndSourceDisappearance() throws {
        let suite = "mixerMac.GraphPersistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = try StandardNodeRegistry.make()
        try registry.register(ExternalAttenuator.nodeType) { ExternalAttenuator(id: $0.id) }
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults), nodeRegistry: registry,
            makeCapture: { _, _ in TestAudioCapture() })
        let app = AudioApp(id: "saved.app", name: "Saved", icon: nil, processes: [], isPlaying: false)
        model.refresh(apps: [app], devices: [], defaultOutputID: 0)
        let channel = try #require(model.channels.first)
        let effect = ExternalAttenuator(id: "saved.effect")
        try channel.core.append(effect)
        effect.amount.setValue(0.3)
        let bus = MixBus(id: "saved.bus", nodes: [GainNode(id: "saved.gain", value: -3)])
        try model.core.graph.add(bus)
        let direct = try #require(model.core.graph.connections.first)
        try model.core.graph.disconnect(direct)
        try model.core.graph.connect(direct.source, to: PortAddress(nodeID: bus.id, portID: "input"))
        try model.core.graph.connect(PortAddress(nodeID: bus.id, portID: "output"), to: direct.destination)
        let expected = try GraphSnapshot(model.core.graph)
        model.refresh(apps: [], devices: [], defaultOutputID: 0)
        #expect(model.channels.isEmpty)
        #expect(try GraphSnapshot(model.core.graph) == expected)
        model.shutdown()
        let restored = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults), nodeRegistry: registry,
            makeCapture: { _, _ in TestAudioCapture() })
        defer { restored.shutdown() }
        #expect(restored.documentError == nil)
        #expect(try GraphSnapshot(restored.core.graph) == expected)
        restored.refresh(apps: [app], devices: [], defaultOutputID: 0)
        let reopened = try #require(restored.channels.first)
        #expect(reopened.core === restored.core.channels.first)
        #expect(reopened.core.children.last?.parameters["amount"]?.value == 0.3)
        #expect(try GraphSnapshot(restored.core.graph) == expected)
    }

    @Test @MainActor func unavailableExtensionDoesNotOverwriteItsSavedDocument() throws {
        let suite = "mixerMac.GraphUnknown.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mixer = ConsoleMixer(channels: [ConsoleChannel(id: "app")])
        try mixer.master.append(ExternalAttenuator(id: "missing-extension"))
        let saved = try JSONEncoder().encode(GraphSnapshot(mixer.graph))
        defaults.set(saved, forKey: "mixer.graph.v1")
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults), makeCapture: { _, _ in TestAudioCapture() })
        defer { model.shutdown() }
        #expect(model.documentError != nil)
        model.core.master.pan.setValue(0.5)
        model.refresh(apps: [], devices: [], defaultOutputID: 0)
        #expect(defaults.data(forKey: "mixer.graph.v1") == saved)
        #expect(model.status.contains("Could not restore mixer"))
        #expect(model.status.contains(ExternalAttenuator.nodeType))
    }
}
