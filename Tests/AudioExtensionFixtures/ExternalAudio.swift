import Foundation
import MixerCore
import MixerAudio
@preconcurrency import AVFAudio

@MainActor
public final class ExternalAttenuator: MixerNode {
    public static let nodeType = "fixture.attenuator"
    public let amount = Parameter(value: 0.5, range: 0...1, defaultValue: 0.5, unit: .linearGain)
    public init(id: String) {
        super.init(id: id, typeID: Self.nodeType, ports: [.stereoInput, .stereoOutput], parameters: ["amount": amount])
    }
}

@MainActor
public final class ExternalAttenuatorProcessor: AudioProcessor {
    let attenuation: ExternalAttenuator
    let mixer = AVAudioMixerNode()
    public init(_ attenuation: ExternalAttenuator) {
        self.attenuation = attenuation
        super.init(model: attenuation, nodes: [mixer], inputs: ["input": AudioEndpoint(mixer)], outputs: ["output": AudioEndpoint(mixer)])
    }
    public override func applyParameters(bypassed: Bool) { mixer.outputVolume = bypassed ? 1 : attenuation.amount.value }
}

@MainActor
public final class ExternalConstantInput: MixerNode {
    public struct Configuration: Codable, Equatable, Sendable {
        public let left: Float
        public let right: Float
        public let sampleRate: Double
        public init(left: Float = 0.4, right: Float = 0.2, sampleRate: Double = 48_000) {
            self.left = left; self.right = right; self.sampleRate = sampleRate
        }
    }
    public static let nodeType = "fixture.constant-input"
    public let configuration: Configuration
    public init(id: String, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        super.init(id: id, typeID: Self.nodeType, ports: [.stereoOutput])
    }
    public override func encodeConfiguration() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(configuration)
    }
    public override func validateConfiguration(version: Int, data: Data) throws {
        guard version == configurationVersion,
              try JSONDecoder().decode(Configuration.self, from: data) == configuration else {
            throw SnapshotError.incompatibleNode(id)
        }
    }
}

@MainActor
public final class ExternalConstantSource: AudioSource {
    public enum Failure: Error { case prepare, activate, update }
    public var failPrepare = false
    public var failActivate = false
    public var failUpdate = false
    public private(set) var calls: [String] = []
    let input: ExternalConstantInput
    public init(_ input: ExternalConstantInput) { self.input = input; super.init(model: input) }
    public override func prepareResources() throws -> AudioEndpoint {
        calls.append("prepare")
        if failPrepare { throw Failure.prepare }
        let values = input.configuration
        let format = AVAudioFormat(standardFormatWithSampleRate: values.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let buffers = UnsafeMutableAudioBufferListPointer(buffers)
            for channel in 0..<2 {
                let data = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<Int(frames) { data[frame] = channel == 0 ? values.left : values.right }
            }
            return noErr
        }
        return AudioEndpoint(source)
    }
    public override func activateResources() throws { calls.append("activate"); if failActivate { throw Failure.activate } }
    public override func updateResources() throws { calls.append("update"); if failUpdate { throw Failure.update } }
    public override func releaseResources() { calls.append("release") }
}
