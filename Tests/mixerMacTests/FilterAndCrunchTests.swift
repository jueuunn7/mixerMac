import Foundation
import MixerCore
import MixerStandardNodes
@testable import MixerAudio
@testable import mixerMac
import Testing
@preconcurrency import AVFAudio

struct FilterAndCrunchTests {
    @Test @MainActor func offAndBypassedBanksPreserveOriginalStereoWithoutDoubleMixing() throws {
        let channel = ConsoleChannel(id: "neutral")
        let mixer = ConsoleMixer(channels: [channel])
        let controls = try ConsoleFilters(mixer: mixer)
        let router = try #require(controls.router(channelID: channel.id))
        let original = try render(mixer: mixer, input: channel, frequency: 1000)
        for selection in 1...2 {
            router.selection.setValue(Float(selection))
            controls.banks[selection - 1].crunch.amount.setValue(1)
            let bypassed = try render(mixer: mixer, input: channel, frequency: 1000)
            #expect(zip(original[0], bypassed[0]).allSatisfy { abs($0 - $1) < 0.00001 })
            #expect(zip(original[1], bypassed[1]).allSatisfy { abs($0 - $1) < 0.00001 })
            controls.banks[selection - 1].setBypassed(false)
        }
        router.selection.setValue(0)
        let off = try render(mixer: mixer, input: channel, frequency: 1000)
        #expect(zip(original[0], off[0]).allSatisfy { abs($0 - $1) < 0.00001 })
        router.selection.setValue(1)
        router.setBypassed(true)
        let routeBypass = try render(mixer: mixer, input: channel, frequency: 1000)
        #expect(zip(original[0], routeBypass[0]).allSatisfy { abs($0 - $1) < 0.00001 })
    }

    @Test @MainActor func lowHighAndBandPassRejectUnwantedFrequencies() throws {
        let channel = ConsoleChannel(id: "filter")
        let mixer = ConsoleMixer(channels: [channel])
        let controls = try ConsoleFilters(mixer: mixer)
        try #require(controls.router(channelID: channel.id)).selection.setValue(1)
        let bank = controls.banks[0]
        bank.setBypassed(false)
        bank.filter.frequency.setValue(1000)
        bank.filter.mode.setValue(0)
        let low = try render(mixer: mixer, input: channel, frequency: 100)
        let lowRejected = try render(mixer: mixer, input: channel, frequency: 8000)
        #expect(rms(lowRejected[0]) < rms(low[0]) * 0.1)
        bank.filter.mode.setValue(2)
        let high = try render(mixer: mixer, input: channel, frequency: 8000)
        let highRejected = try render(mixer: mixer, input: channel, frequency: 100)
        #expect(rms(highRejected[0]) < rms(high[0]) * 0.1)
        bank.filter.mode.setValue(1)
        let mid = try render(mixer: mixer, input: channel, frequency: 1000)
        let below = try render(mixer: mixer, input: channel, frequency: 50)
        let above = try render(mixer: mixer, input: channel, frequency: 10000)
        #expect(rms(below[0]) < rms(mid[0]) * 0.2)
        #expect(rms(above[0]) < rms(mid[0]) * 0.2)
    }

    @Test @MainActor func banksAreIndependentAndResonanceRaisesTheCutoffRegion() throws {
        let channel = ConsoleChannel(id: "banks")
        let mixer = ConsoleMixer(channels: [channel])
        let controls = try ConsoleFilters(mixer: mixer)
        let route = try #require(controls.router(channelID: channel.id))
        route.selection.setValue(1)
        controls.banks[0].setBypassed(false)
        controls.banks[0].filter.frequency.setValue(1000)
        let mild = try render(mixer: mixer, input: channel, frequency: 1000)
        controls.banks[0].filter.resonance.setValue(0.8)
        let resonant = try render(mixer: mixer, input: channel, frequency: 1000)
        #expect(rms(resonant[0]) > rms(mild[0]) * 1.4)
        controls.banks[1].setBypassed(false)
        controls.banks[1].filter.mode.setValue(2)
        controls.banks[1].filter.frequency.setValue(8000)
        route.selection.setValue(2)
        let other = try render(mixer: mixer, input: channel, frequency: 1000)
        #expect(rms(other[0]) < rms(mild[0]) * 0.2)
        #expect(controls.banks[0].filter.resonance.value == 0.8)
    }

    @Test @MainActor func crunchAddsHarmonicsBeforeFilterAndZeroOrBypassPreserveSignal() throws {
        let channel = ConsoleChannel(id: "crunch")
        let crunch = CrunchNode(id: "standalone-crunch")
        try channel.append(crunch)
        let mixer = ConsoleMixer(channels: [channel])
        let dry = try render(mixer: mixer, input: channel, frequency: 1000, rightAmplitude: 0)
        crunch.amount.setValue(1)
        let driven = try render(mixer: mixer, input: channel, frequency: 1000, rightAmplitude: 0)
        #expect(harmonic(driven[0], frequency: 3000) > 0.005)
        #expect(harmonic(dry[0], frequency: 3000) < 0.00001)
        #expect(driven[1].allSatisfy { $0 == 0 })
        #expect(driven.flatMap { $0 }.allSatisfy { $0.isFinite })
        crunch.setBypassed(true)
        let bypass = try render(mixer: mixer, input: channel, frequency: 1000, rightAmplitude: 0)
        #expect(zip(dry[0], bypass[0]).allSatisfy { abs($0 - $1) < 0.00001 })
        try channel.remove(id: crunch.id)
        let controls = try ConsoleFilters(mixer: mixer)
        let bank = controls.banks[0]
        bank.setBypassed(false)
        bank.crunch.amount.setValue(1)
        bank.filter.frequency.setValue(1200)
        try #require(controls.router(channelID: channel.id)).selection.setValue(1)
        let filtered = try render(mixer: mixer, input: channel, frequency: 1000, rightAmplitude: 0)
        #expect(harmonic(filtered[0], frequency: 3000) < harmonic(driven[0], frequency: 3000) * 0.5)
        #expect(bank.children[0] === bank.crunch)
        #expect(bank.children[1] === bank.filter)
    }

    @Test @MainActor func mutedAndFadedChannelsDoNotReachSharedFilters() throws {
        let channel = ConsoleChannel(id: "muted")
        let mixer = ConsoleMixer(channels: [channel])
        let controls = try ConsoleFilters(mixer: mixer)
        try #require(controls.router(channelID: channel.id)).selection.setValue(1)
        controls.banks[0].setBypassed(false)
        controls.banks[0].crunch.amount.setValue(1)
        channel.setMuted(true)
        let muted = try render(mixer: mixer, input: channel, frequency: 1000)
        #expect(muted.flatMap { $0 }.allSatisfy { $0 == 0 })
        channel.setMuted(false)
        channel.volume.setValue(0)
        let faded = try render(mixer: mixer, input: channel, frequency: 1000)
        #expect(faded.flatMap { $0 }.allSatisfy { $0 == 0 })
    }

    @Test @MainActor func liveControlsPreservePlaybackAndSurviveReopening() throws {
        let domain = "mixerMac.Filters.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let processing = TestChannelProcessing()
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults),
            sources: try processing.registry(), audioOutput: processing.output,
            discoverOwnProcesses: { [99] }, makeCapture: { _, _ in TestAudioCapture() })
        defer { model.shutdown() }
        let app = AudioApp(id: "app", name: "App", icon: nil, processes: [11], isPlaying: false)
        model.refresh(apps: [app], devices: [OutputDevice(id: 42, name: "Offline", uid: "offline")], defaultOutputID: 42)
        model.toggleMixing()
        #expect(model.isMixing)
        let controls = try #require(model.filters)
        let route = try #require(controls.router(channelID: app.id))
        let topology = model.core.graph.topologyRevision
        let starts = processing.output.starts
        controls.banks[0].setBypassed(false)
        controls.banks[0].crunch.amount.setValue(0.5)
        controls.banks[0].filter.frequency.setValue(2500)
        controls.banks[1].filter.mode.setValue(2)
        for selection in [1, 2, 0, 1] { route.selection.setValue(Float(selection)) }
        try controls.connectChannels()
        #expect(model.core.graph.topologyRevision == topology)
        #expect(processing.output.starts == starts)
        #expect(model.isMixing)
        let snapshot = try GraphSnapshot(model.core.graph)
        let reopened = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults), makeCapture: { _, _ in TestAudioCapture() })
        defer { reopened.shutdown() }
        #expect(reopened.documentError == nil)
        #expect(try GraphSnapshot(reopened.core.graph) == snapshot)
        #expect(reopened.filters?.router(channelID: app.id)?.selection.value == 1)
        #expect(reopened.filters?.banks[0].crunch.amount.value == 0.5)
    }

    @Test @MainActor func previousBuiltInsAreRemovedWithOriginalGraphAndChannelBackedUp() throws {
        let domain = "mixerMac.FilterMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let channel = ConsoleChannel(id: "old")
        channel.equalizer.bands[9].gain.setValue(-4)
        let current = try NodeSnapshot(channel)
        let compressor = MixerNode(id: "old.compressor", typeID: "standard.compressor", ports: [.stereoInput, .stereoOutput])
        let old = NodeSnapshot(id: current.id, typeID: current.typeID, structure: current.structure, configurationVersion: 3,
            configuration: current.configuration, ports: current.ports, parameters: current.parameters, isBypassed: current.isBypassed,
            children: [current.children[0], try NodeSnapshot(compressor)] + Array(current.children.dropFirst()))
        let reverb = MixerNode(id: "console.fx.reverb", typeID: "standard.reverb-return", ports: [.stereoInput, .stereoOutput])
        let send = MixerNode(id: "old.send.console.fx.reverb", typeID: "standard.send", ports: [.stereoInput, .stereoOutput])
        let graph = GraphSnapshot(version: 1, nodes: [old, try NodeSnapshot(ConsoleBus()), try NodeSnapshot(reverb), try NodeSnapshot(send)], connections: [
            AudioConnection(source: PortAddress(nodeID: "old", portID: "output"), destination: PortAddress(nodeID: "master", portID: "input")),
            AudioConnection(source: PortAddress(nodeID: "old", portID: "output"), destination: PortAddress(nodeID: send.id, portID: "input")),
            AudioConnection(source: PortAddress(nodeID: send.id, portID: "output"), destination: PortAddress(nodeID: reverb.id, portID: "input")),
            AudioConnection(source: PortAddress(nodeID: reverb.id, portID: "output"), destination: PortAddress(nodeID: "master", portID: "input"))
        ])
        let original = try JSONEncoder().encode(graph)
        let oldChannel = try JSONEncoder().encode(old)
        defaults.set(original, forKey: "mixer.graph.v1")
        defaults.set(oldChannel, forKey: "channel.nodes.old")
        let model = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
        defer { model.shutdown() }
        #expect(model.documentError == nil)
        #expect(defaults.data(forKey: "backup.beforeFilterOnly.mixer.graph.v1") == original)
        let restored = try #require(model.core.channels.first as? ConsoleChannel)
        #expect(restored.equalizer.bands.count == 10)
        #expect(restored.equalizer.bands[9].gain.value == -4)
        #expect(!restored.children.contains { $0.typeID == "standard.compressor" })
        #expect(!model.core.graph.nodes.contains { $0.id == reverb.id || $0.id == send.id })
        let standalone = AppAudioChannel(app: AudioApp(id: "old", name: "Old", icon: nil, processes: [], isPlaying: false), defaults: defaults)
        #expect(standalone.restorationError == nil)
        #expect(defaults.data(forKey: "backup.beforeFilterOnly.channel.nodes.old") == oldChannel)
        model.core.master.pan.setValue(0.2)
        let reopened = MixerConsoleModel(preferences: ConsolePreferences(defaults: defaults))
        defer { reopened.shutdown() }
        #expect(reopened.documentError == nil)
        #expect(defaults.data(forKey: "backup.beforeFilterOnly.mixer.graph.v1") == original)
    }

    @Test @MainActor func customRoutesRemainUnchangedAndAreNotForcedThroughFilters() throws {
        let channel = ConsoleChannel(id: "custom")
        let mixer = ConsoleMixer(channels: [channel])
        let bus = MixBus(id: "external-bus")
        let dry = mixer.graph.connections[0]
        try mixer.graph.replace(nodes: mixer.graph.nodes + [bus], connections: [
            AudioConnection(source: dry.source, destination: PortAddress(nodeID: bus.id, portID: "input")),
            AudioConnection(source: PortAddress(nodeID: bus.id, portID: "output"), destination: dry.destination)
        ])
        let controls = try ConsoleFilters(mixer: mixer)
        #expect(controls.router(channelID: channel.id) == nil)
        #expect(mixer.graph.connections.contains { $0.source == dry.source && $0.destination.nodeID == bus.id })
    }

    @MainActor
    private func render(mixer: ConsoleMixer, input: ConsoleChannel, frequency: Double, rightAmplitude: Float = 0.1) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let frames = 48000
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        source.frameLength = UInt32(frames)
        for frame in 0..<frames {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / 48000))
            source.floatChannelData![0][frame] = 0.2 * value
            source.floatChannelData![1][frame] = rightAmplitude * value
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let renderer = AudioGraphRenderer(engine: engine, format: format, registry: try StandardAudioProcessors.make())
        try renderer.rebuild(mixer.graph, output: PortAddress(nodeID: mixer.master.id, portID: "output"),
            externalInputs: [PortAddress(nodeID: input.id, portID: "input"): AudioEndpoint(player)])
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        try engine.start()
        defer { engine.stop(); renderer.detach() }
        player.scheduleBuffer(source)
        player.play()
        var result = [[Float](), [Float]()]
        while result[0].count < frames {
            let count = UInt32(min(1024, frames - result[0].count))
            #expect(try engine.renderOffline(count, to: block) == .success)
            for side in 0..<2 { result[side].append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![side], count: Int(count))) }
        }
        return result
    }

    private func rms(_ samples: [Float]) -> Float {
        let steady = samples.suffix(24000)
        return sqrt(steady.reduce(0) { $0 + $1 * $1 } / Float(steady.count))
    }

    private func harmonic(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for frame in 24000..<48000 {
            let angle = 2 * .pi * frequency * Double(frame) / 48000
            real += Double(samples[frame]) * cos(angle)
            imaginary -= Double(samples[frame]) * sin(angle)
        }
        return 2 * hypot(real, imaginary) / 24000
    }
}
