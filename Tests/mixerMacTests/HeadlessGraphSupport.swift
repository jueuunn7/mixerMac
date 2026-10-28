import Foundation
import MixerCore
import MixerStandardNodes
@testable import MixerAudio
import Testing
@preconcurrency import AVFAudio

@MainActor
final class OfflineAudioOutput: AudioOutput {
    let engine = AVAudioEngine()
    private(set) var starts = 0
    var failingStarts = 0
    func start(device: OutputDevice) throws {
        starts += 1
        if failingStarts > 0 {
            failingStarts -= 1
            throw TestAudioCapture.Failure.unavailable
        }
        if engine.manualRenderingMode != .offline {
            try engine.enableManualRenderingMode(.offline,
                format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 4096)
        }
        try engine.start()
    }
    func stop() { engine.stop() }
}

@MainActor
final class TestChannelProcessing {
    var failingIDs: Set<String> = []
    var ownProcesses: [UInt32] = [99]
    private(set) var starts: [String] = []
    let output = OfflineAudioOutput()
    func registry() throws -> AudioSourceRegistry {
        let registry = AudioSourceRegistry()
        try registry.register(ApplicationInput.sourceType, nodeType: ApplicationInput.self) { [self] input in
            TestApplicationSource(input, owner: self)
        }
        return registry
    }
    func didPrepare(_ input: ApplicationInput) throws {
        starts.append(input.app.id)
        if failingIDs.contains(input.app.id) { throw TestAudioCapture.Failure.unavailable }
    }
}

@MainActor
private final class TestApplicationSource: AudioSource {
    let input: ApplicationInput
    let owner: TestChannelProcessing
    init(_ input: ApplicationInput, owner: TestChannelProcessing) { self.input = input; self.owner = owner; super.init(model: input) }
    override func prepareResources() throws -> AudioEndpoint {
        try owner.didPrepare(input)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let node = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                buffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(frames) * MemoryLayout<Float>.size)
            }
            return noErr
        }
        return AudioEndpoint(node)
    }
}

@MainActor
func renderConsolePCM(_ source: AVAudioPCMBuffer, settings: ChannelSettings = ChannelSettings(),
                      master: BusEQSettings = BusEQSettings(), preFader: Bool = false) throws -> AVAudioPCMBuffer {
    let channel = ConsoleChannel(id: "render-channel", settings: settings)
    let mixer = ConsoleMixer(channels: [channel], masterSettings: master)
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let renderer = AudioGraphRenderer(engine: engine, format: source.format, registry: try StandardAudioProcessors.make())
    try renderer.rebuild(mixer.graph,
        output: PortAddress(nodeID: preFader ? channel.equalizer.id : mixer.master.id, portID: "output"),
        externalInputs: [PortAddress(nodeID: channel.id, portID: "input"): AudioEndpoint(player)])
    try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: source.frameLength)
    let output = try #require(AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength))
    try engine.start()
    defer { engine.stop(); renderer.detach() }
    player.scheduleBuffer(source, at: nil, options: .loops)
    player.play()
    for _ in 0..<5 { #expect(try engine.renderOffline(source.frameLength, to: output) == .success) }
    return output
}

@MainActor
func renderedConsolePeak(settings: ChannelSettings = ChannelSettings(), master: BusEQSettings = BusEQSettings(),
                         preFader: Bool = false, frequency: Double = 48_000.0 * 85 / 4096, frames: Int = 4096,
                         amplitude: Float = 0.1) throws -> Float {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
    source.frameLength = UInt32(frames)
    for frame in 0..<frames {
        let value = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / 48_000))
        for channel in 0..<2 { source.floatChannelData![channel][frame] = value }
    }
    let output = try renderConsolePCM(source, settings: settings, master: master, preFader: preFader)
    return (0..<frames).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0
}
