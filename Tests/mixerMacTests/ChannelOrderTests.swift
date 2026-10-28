import Foundation
import MixerCore
import MixerStandardNodes
@testable import MixerAudio
import Testing
@testable import mixerMac

struct ChannelOrderTests {
    @Test @MainActor func movingFiveLiveChannelsPreservesPlaybackAndSurvivesDiscoveryAndRestart() throws {
        let suite = "mixerMac.ChannelOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let processing = TestChannelProcessing()
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults),
            sources: try processing.registry(), audioOutput: processing.output,
            discoverOwnProcesses: { [99] }, makeCapture: { _, _ in TestAudioCapture() })
        defer { model.shutdown() }
        let apps = (1...5).map { AudioApp(id: "app\($0)", name: "App \($0)", icon: nil, processes: [UInt32($0 + 10)], isPlaying: false) }
        let device = OutputDevice(id: 42, name: "Offline", uid: "offline")
        model.refresh(apps: apps, devices: [device], defaultOutputID: device.id)
        model.toggleMixing()
        #expect(model.isMixing)
        let channels = model.channels
        let graph = try GraphSnapshot(model.core.graph)
        let topology = model.core.graph.topologyRevision
        let starts = processing.output.starts
        #expect(model.moveChannel(id: "app1", relativeTo: "app3", after: true))
        #expect(model.channels.map(\.id) == ["app2", "app3", "app1", "app4", "app5"])
        #expect(model.moveChannel(id: "app5", relativeTo: "app2"))
        let order = ["app5", "app2", "app3", "app1", "app4"]
        #expect(model.channels.map(\.id) == order)
        #expect(model.channels.allSatisfy { channel in channels.contains { $0 === channel } })
        #expect(model.channels.allSatisfy { $0.isProcessing })
        #expect(model.core.graph.topologyRevision == topology)
        #expect(try GraphSnapshot(model.core.graph) == graph)
        #expect(processing.output.starts == starts)
        model.refresh(apps: apps.reversed(), devices: [device], defaultOutputID: device.id)
        #expect(model.channels.map(\.id) == order)
        #expect(processing.output.starts == starts)
        let restored = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults), makeCapture: { _, _ in TestAudioCapture() })
        defer { restored.shutdown() }
        restored.refresh(apps: apps, devices: [], defaultOutputID: 0)
        #expect(restored.channels.map(\.id) == order)
        restored.refresh(apps: apps.filter { $0.id != "app3" }, devices: [], defaultOutputID: 0)
        #expect(restored.channels.map(\.id) == order.filter { $0 != "app3" })
        restored.refresh(apps: apps + [AudioApp(id: "new", name: "New", icon: nil, processes: [], isPlaying: false)], devices: [], defaultOutputID: 0)
        #expect(restored.channels.map(\.id) == order + ["new"])
        #expect(!restored.moveChannel(id: "missing", relativeTo: "app2"))
        #expect(!restored.moveChannel(id: "app2", relativeTo: "missing"))
        #expect(!restored.moveChannel(id: "app2", relativeTo: "app2"))
    }
}
