import AudioToolbox
import CoreAudio
import MixerCore
@preconcurrency import AVFAudio

@MainActor
public protocol AudioOutput {
    var engine: AVAudioEngine { get }
    func start(device: OutputDevice) throws
    func stop()
}

@MainActor
public final class DeviceAudioOutput: AudioOutput {
    public let engine = AVAudioEngine()
    public init() {}
    public func start(device: OutputDevice) throws {
        guard let unit = engine.outputNode.audioUnit else {
            throw AudioDevices.RoutingError(operation: "Open mixer output", status: -1)
        }
        var deviceID = device.id
        try AudioDevices.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "Select mixer output")
        try engine.start()
    }
    public func stop() { engine.stop() }
}

public struct AudioSourceBinding {
    public let model: MixerNode
    public let destination: PortAddress
    public init(model: MixerNode, destination: PortAddress) { self.model = model; self.destination = destination }
}

@MainActor
public final class AudioGraphPlayback {
    private struct Input { let binding: AudioSourceBinding; let source: AudioSource }
    public private(set) var isRunning = false
    private let graph: AudioGraph
    private let destination: PortAddress
    private let output: any AudioOutput
    private let sources: AudioSourceRegistry
    private let renderer: AudioGraphRenderer
    private var inputs: [String: Input] = [:]
    private var device: OutputDevice?
    private var feeds: [PortAddress: PCMFeed] = [:]

    public init(graph: AudioGraph, destination: PortAddress, output: any AudioOutput,
                sources: AudioSourceRegistry, processors: AudioProcessorRegistry, format: AVAudioFormat) {
        self.graph = graph
        self.destination = destination
        self.output = output
        self.sources = sources
        renderer = AudioGraphRenderer(engine: output.engine, format: format, registry: processors)
    }

    public func start(device: OutputDevice, bindings: [AudioSourceBinding], feeds: [PortAddress: PCMFeed] = [:]) throws {
        stop()
        self.device = device
        self.feeds = feeds
        do {
            for binding in bindings { try prepare(binding) }
            try rebuild()
            try output.start(device: device)
            for input in inputs.values { try input.source.activate() }
            isRunning = true
        } catch { stop(); throw error }
    }

    public func connect(_ binding: AudioSourceBinding, feeds: [PortAddress: PCMFeed]) throws {
        guard isRunning, let device else { throw AudioSourceError.invalidState }
        if let existing = inputs[binding.model.id] {
            guard existing.binding.model === binding.model,
                  existing.binding.destination == binding.destination else {
                throw AudioSourceError.incompatibleSource(binding.model.id)
            }
            return
        }
        // A failed source never interrupts already running sources or their engine.
        try prepare(binding)
        self.feeds = feeds
        output.stop()
        do {
            try rebuild()
            try output.start(device: device)
            try inputs[binding.model.id]!.source.activate()
        } catch {
            removeInput(binding.model.id)
            do {
                if renderer.isCurrent(for: graph) { try rebuild() }
                renderer.apply()
                try output.start(device: device)
            }
            catch { stop() }
            throw error
        }
    }

    public func apply(feeds: [PortAddress: PCMFeed], activeSourceIDs: Set<String>? = nil) throws {
        guard isRunning, let device else { return }
        self.feeds = feeds
        let removed = inputs.values.filter { input in
            !(activeSourceIDs?.contains(input.binding.model.id) ?? true)
                || !graph.nodes.contains { $0.id == input.binding.destination.nodeID }
        }.map { $0.binding.model.id }
        if !renderer.isCurrent(for: graph) || !removed.isEmpty {
            output.stop()
            for id in removed { removeInput(id) }
            do {
                try rebuild()
                try output.start(device: device)
            }
            catch {
                // Validation failure leaves the previous renderer intact.
                renderer.apply()
                do { try output.start(device: device) }
                catch { stop() }
                throw error
            }
        } else { renderer.apply() }
    }

    public func source(id: String) -> AudioSource? { inputs[id]?.source }

    public func stop() {
        output.stop()
        renderer.detach()
        for id in Array(inputs.keys) { removeInput(id) }
        device = nil
        isRunning = false
    }

    private func prepare(_ binding: AudioSourceBinding) throws {
        guard inputs[binding.model.id] == nil,
              !inputs.values.contains(where: { $0.binding.destination == binding.destination }) else {
            throw AudioSourceError.incompatibleSource(binding.model.id)
        }
        let source = try sources.make(binding.model)
        let endpoint = try source.prepare()
        guard endpoint.node.engine == nil, endpoint.bus < endpoint.node.numberOfOutputs else {
            source.stop()
            throw AudioSourceError.incompatibleSource(binding.model.id)
        }
        output.engine.attach(endpoint.node)
        inputs[binding.model.id] = Input(binding: binding, source: source)
    }

    private func rebuild() throws {
        let external = Dictionary(uniqueKeysWithValues: inputs.values.map { ($0.binding.destination, $0.source.endpoint!) })
        try renderer.rebuild(graph, output: destination, externalInputs: external, feeds: feeds)
    }

    private func removeInput(_ id: String) {
        guard let input = inputs.removeValue(forKey: id) else { return }
        if let endpoint = input.source.endpoint {
            output.engine.disconnectNodeOutput(endpoint.node)
            output.engine.detach(endpoint.node)
        }
        input.source.stop()
    }
}
