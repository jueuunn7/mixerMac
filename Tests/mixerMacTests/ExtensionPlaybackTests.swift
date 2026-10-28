import Foundation
import MixerCore
import MixerStandardNodes
import MixerAudioExtensionFixtures
@testable import MixerAudio
import Testing
@preconcurrency import AVFAudio

struct ExtensionPlaybackTests {
    @Test(arguments: [false, true]) @MainActor func sourceLifecycleCleanupIsInheritedAfterPartialFailure(activationFails: Bool) throws {
        let source = ExternalConstantSource(ExternalConstantInput(id: "source"))
        source.failPrepare = !activationFails
        source.failActivate = activationFails
        if activationFails {
            _ = try source.prepare()
            #expect(source.state == .prepared)
            #expect(throws: ExternalConstantSource.Failure.activate) { try source.activate() }
            #expect(source.calls == ["prepare", "activate", "release"])
        } else {
            #expect(throws: ExternalConstantSource.Failure.prepare) { try source.prepare() }
            #expect(source.calls == ["prepare", "release"])
        }
        #expect(source.state == .failed)
        #expect(source.endpoint == nil)
        source.stop()
        source.stop()
        #expect(source.calls.filter { $0 == "release" }.count == 1)
        source.failPrepare = false
        source.failActivate = false
        _ = try source.prepare()
        try source.activate()
        #expect(source.state == .running)
        source.failUpdate = true
        #expect(throws: ExternalConstantSource.Failure.update) { try source.synchronize() }
        #expect(source.state == .running)
        source.stop()
        #expect(source.calls.filter { $0 == "release" }.count == 2)
    }

    @Test(arguments: [44_100.0, 48_000.0]) @MainActor
    func externalSourceAndEffectRunInProductionPlaybackAndTopologyEditsTakeEffect(sampleRate: Double) throws {
        let channel = Channel(id: "input")
        let master = MixBus(id: "master")
        let mixer = Mixer(master: master, channels: [channel])
        let registry = try StandardAudioProcessors.make()
        try registry.register(ExternalAttenuator.nodeType, nodeType: ExternalAttenuator.self) { ExternalAttenuatorProcessor($0) }
        let sources = AudioSourceRegistry()
        let input = ExternalConstantInput(id: "source", configuration: .init(sampleRate: sampleRate))
        let source = ExternalConstantSource(input)
        try sources.register(ExternalConstantInput.nodeType, nodeType: ExternalConstantInput.self) { _ in source }
        let output = OfflineAudioOutput()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let playback = AudioGraphPlayback(graph: mixer.graph, destination: PortAddress(nodeID: master.id, portID: "output"),
            output: output, sources: sources, processors: registry, format: format)
        try playback.start(device: OutputDevice(id: 42, name: "Offline", uid: "offline"), bindings: [
            AudioSourceBinding(model: input, destination: PortAddress(nodeID: channel.id, portID: "input"))
        ])
        defer { playback.stop() }
        let originalDestination = PortAddress(nodeID: channel.id, portID: "input")
        let startsBeforeRepeat = output.starts
        try playback.connect(AudioSourceBinding(model: input, destination: originalDestination), feeds: [:])
        #expect(output.starts == startsBeforeRepeat)
        let alias = ExternalConstantInput(id: input.id)
        #expect(throws: AudioSourceError.incompatibleSource(input.id)) {
            try playback.connect(AudioSourceBinding(model: alias, destination: originalDestination), feeds: [:])
        }
        #expect(throws: AudioSourceError.incompatibleSource(input.id)) {
            try playback.connect(AudioSourceBinding(model: input, destination: PortAddress(nodeID: master.id, portID: "input")), feeds: [:])
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        #expect(try output.engine.renderOffline(4096, to: buffer) == .success)
        #expect(abs(buffer.floatChannelData![0][4095] - 0.4) < 0.001)
        let effect = ExternalAttenuator(id: "added-live")
        try channel.append(effect)
        try playback.apply(feeds: [:])
        #expect(try output.engine.renderOffline(4096, to: buffer) == .success)
        #expect(abs(buffer.floatChannelData![0][4095] - 0.2) < 0.001)
        effect.amount.setValue(0.25)
        let starts = output.starts
        try playback.apply(feeds: [:])
        #expect(output.starts == starts)
        #expect(try output.engine.renderOffline(4096, to: buffer) == .success)
        #expect(abs(buffer.floatChannelData![0][4095] - 0.1) < 0.001)
        let unknown = MixerNode(id: "unsupported", typeID: "unknown.effect", ports: [.stereoInput, .stereoOutput])
        try channel.append(unknown)
        #expect(throws: AudioGraphError.unregisteredType("unknown.effect")) { try playback.apply(feeds: [:]) }
        #expect(playback.isRunning)
        #expect(try output.engine.renderOffline(4096, to: buffer) == .success)
        #expect(abs(buffer.floatChannelData![0][4095] - 0.1) < 0.001)
        try channel.remove(id: unknown.id)
        try playback.apply(feeds: [:])
        playback.stop()
        #expect(source.state == .stopped)
        #expect(source.calls == ["prepare", "activate", "release"])
    }

    @Test @MainActor func sourceConfigurationRoundTripsThroughTheCommonRegistry() throws {
        let input = ExternalConstantInput(id: "source", configuration: .init(left: -0.1, right: 0.3, sampleRate: 44_100))
        let registry = NodeRegistry()
        try registry.register(ExternalConstantInput.nodeType) { snapshot in
            guard snapshot.configurationVersion == 1 else { throw SnapshotError.unsupportedVersion(snapshot.configurationVersion) }
            let configuration = try JSONDecoder().decode(ExternalConstantInput.Configuration.self, from: snapshot.configuration)
            return ExternalConstantInput(id: snapshot.id, configuration: configuration)
        }
        let snapshot = try NodeSnapshot(input)
        let restored = try #require(try registry.makeNode(from: snapshot) as? ExternalConstantInput)
        #expect(restored.configuration == input.configuration)
        #expect(try NodeSnapshot(restored) == snapshot)
    }
}

extension ExtensionPlaybackTests {
    @Test @MainActor func muteAndVolumeStillApplyWhileAnInvalidStagePreventsRebuild() throws {
        let effect = ExternalAttenuator(id: "gain")
        let channel = Channel(id: "channel", nodes: [effect])
        let master = MixBus(id: "master")
        let mixer = Mixer(master: master, channels: [channel])
        let processors = try StandardAudioProcessors.make()
        try processors.register(ExternalAttenuator.nodeType, nodeType: ExternalAttenuator.self) { ExternalAttenuatorProcessor($0) }
        let sources = AudioSourceRegistry()
        let input = ExternalConstantInput(id: "source")
        try sources.register(ExternalConstantInput.nodeType, nodeType: ExternalConstantInput.self) { ExternalConstantSource($0) }
        let output = OfflineAudioOutput()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let playback = AudioGraphPlayback(graph: mixer.graph, destination: PortAddress(nodeID: master.id, portID: "output"),
            output: output, sources: sources, processors: processors, format: format)
        let binding = AudioSourceBinding(model: input, destination: PortAddress(nodeID: channel.id, portID: "input"))
        try playback.start(device: OutputDevice(id: 42, name: "Offline", uid: "offline"), bindings: [binding])
        defer { playback.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        #expect(try output.engine.renderOffline(4096, to: buffer) == .success)
        #expect(abs(buffer.floatChannelData![0][4095] - 0.2) < 0.001)
        try channel.append(MixerNode(id: "invalid", typeID: "unknown.effect", ports: [.stereoInput, .stereoOutput]))
        channel.setMuted(true)
        #expect(throws: AudioGraphError.unregisteredType("unknown.effect")) { try playback.apply(feeds: [:]) }
        #expect(playback.isRunning)
        #expect(try output.engine.renderOffline(4096, to: buffer) == .success)
        #expect(buffer.floatChannelData![0][4095] == 0)
        channel.setMuted(false)
        effect.amount.setValue(0.25)
        #expect(throws: AudioGraphError.unregisteredType("unknown.effect")) { try playback.apply(feeds: [:]) }
        #expect(try output.engine.renderOffline(4096, to: buffer) == .success)
        #expect(abs(buffer.floatChannelData![0][4095] - 0.1) < 0.001)
    }
}
