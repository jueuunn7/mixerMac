import MixerCore
import MixerStandardNodes
import MixerAudioExtensionFixtures
@testable import MixerAudio
import Testing
@preconcurrency import AVFAudio

struct GraphRenderingTests {
    @MainActor
    private func render(_ graph: AudioGraph, output: String, inputs: [String: (Float, Float)],
                        registry: AudioProcessorRegistry, frames: UInt32 = 4096) throws -> (Float, Float) {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let engine = AVAudioEngine()
        let renderer = AudioGraphRenderer(engine: engine, format: format, registry: registry)
        var endpoints: [PortAddress: AudioEndpoint] = [:]
        for (id, pair) in inputs {
            let source = AVAudioSourceNode(format: format) { _, _, count, buffers in
                let buffers = UnsafeMutableAudioBufferListPointer(buffers)
                for index in 0..<2 {
                    let data = buffers[index].mData!.assumingMemoryBound(to: Float.self)
                    for frame in 0..<Int(count) { data[frame] = index == 0 ? pair.0 : pair.1 }
                }
                return noErr
            }
            engine.attach(source)
            endpoints[PortAddress(nodeID: id, portID: "input")] = AudioEndpoint(source)
        }
        try renderer.rebuild(graph, output: PortAddress(nodeID: output, portID: "output"), externalInputs: endpoints)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        try engine.start()
        defer { engine.stop(); renderer.detach() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        #expect(try engine.renderOffline(frames, to: buffer) == .success)
        let data = try #require(buffer.floatChannelData)
        return (data[0][Int(frames) - 1], data[1][Int(frames) - 1])
    }

    @Test @MainActor func registeredExternalEffectRunsThroughSerialChainAndTwoRoutingBranches() throws {
        let registry = try StandardAudioProcessors.make()
        try registry.register(ExternalAttenuator.nodeType, nodeType: ExternalAttenuator.self) { ExternalAttenuatorProcessor($0) }
        let first = Channel(id: "first", nodes: [ExternalAttenuator(id: "external-effect")])
        let second = Channel(id: "second")
        let submix = MixBus(id: "submix", nodes: [GainNode(id: "attenuate", value: -6.0206)])
        let master = MixBus(id: "master")
        let graph = AudioGraph()
        func edge(_ source: String, _ destination: String) -> AudioConnection {
            AudioConnection(source: PortAddress(nodeID: source, portID: "output"), destination: PortAddress(nodeID: destination, portID: "input"))
        }
        try graph.replace(nodes: [first, second, submix, master], connections: [
            edge("first", "submix"), edge("first", "master"), edge("second", "submix"), edge("submix", "master")
        ])
        let result = try render(graph, output: "master", inputs: ["first": (0.2, 0.4), "second": (0.2, 0.1)], registry: registry)
        #expect(abs(result.0 - 0.25) < 0.001)
        #expect(abs(result.1 - 0.35) < 0.001)
    }

    @Test @MainActor func nestedBypassVolumeZeroAndMuteSoloAreRendered() throws {
        let registry = try StandardAudioProcessors.make()
        let first = ConsoleChannel(id: "first")
        let second = ConsoleChannel(id: "second")
        let mixer = ConsoleMixer(channels: [first, second])
        first.volume.setValue(0)
        second.setSolo(true)
        var result = try render(mixer.graph, output: "master", inputs: ["first": (0.2, 0.4), "second": (0.3, 0.1)], registry: registry)
        #expect(abs(result.0 - 0.3) < 0.001)
        #expect(abs(result.1 - 0.1) < 0.001)
        second.setMuted(true)
        result = try render(mixer.graph, output: "master", inputs: ["first": (0.2, 0.4), "second": (0.3, 0.1)], registry: registry)
        #expect(result.0 == 0 && result.1 == 0)
        second.setSolo(false)
        first.setBypassed(true)
        result = try render(mixer.graph, output: "master", inputs: ["first": (0.2, 0.4), "second": (0.3, 0.1)], registry: registry)
        #expect(abs(result.0 - 0.2) < 0.001)
        #expect(abs(result.1 - 0.4) < 0.001)
    }

    @Test(arguments: [Float(0), 1, 2]) @MainActor func stereoWidthRunsAtItsGraphPosition(width: Float) throws {
        let channel = ConsoleChannel(id: "first")
        let mixer = ConsoleMixer(channels: [channel])
        mixer.master.width.setValue(width)
        let result = try render(mixer.graph, output: "master", inputs: ["first": (0.4, 0.2)], registry: StandardAudioProcessors.make())
        #expect(abs(result.0 - (0.3 + 0.1 * width)) < 0.001)
        #expect(abs(result.1 - (0.3 - 0.1 * width)) < 0.001)
    }
}

extension GraphRenderingTests {
    @Test(arguments: [Float(-1), 0, 0.5, 1]) @MainActor func stereoBalanceAndItsBypassAreRendered(pan: Float) throws {
        let channel = ConsoleChannel(id: "channel")
        channel.pan.setValue(pan)
        let mixer = ConsoleMixer(channels: [channel])
        let registry = try StandardAudioProcessors.make()
        var samples = try render(mixer.graph, output: "master", inputs: [channel.id: (0.4, 0.2)], registry: registry)
        #expect(abs(samples.0 - 0.4 * min(1, 1 - pan)) < 0.001)
        #expect(abs(samples.1 - 0.2 * min(1, 1 + pan)) < 0.001)
        channel.panStage.setBypassed(true)
        samples = try render(mixer.graph, output: "master", inputs: [channel.id: (0.4, 0.2)], registry: registry)
        #expect(abs(samples.0 - 0.4) < 0.001)
        #expect(abs(samples.1 - 0.2) < 0.001)
    }

    @Test @MainActor func disconnectedSoloChannelDoesNotSilenceAnActiveSource() throws {
        let live = ConsoleChannel(id: "live")
        let offline = ConsoleChannel(id: "offline")
        offline.setSolo(true)
        let mixer = ConsoleMixer(channels: [live, offline])
        let samples = try render(mixer.graph, output: "master", inputs: [live.id: (0.4, 0.2)], registry: StandardAudioProcessors.make())
        #expect(abs(samples.0 - 0.4) < 0.001)
        #expect(abs(samples.1 - 0.2) < 0.001)
    }
}
