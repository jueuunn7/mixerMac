import AppKit
import Combine
import CoreAudio
import MixerCore
import MixerStandardNodes

@MainActor
public final class ChannelAudioMetrics: ObservableObject {
    public init() {}
    @Published public private(set) var level: Float = 0
    @Published public private(set) var heldPeak: Float = 0
    private var peakHold = MeterPeakHold()

    public func setLevel(_ value: Float, peak: Float? = nil) {
        let quantized = (min(1, max(0, value)) * 120).rounded(.down) / 120
        if quantized != level { level = quantized }
        peakHold.update(peak ?? value, now: ProcessInfo.processInfo.systemUptime)
        let peakSegment = (peakHold.level * 120).rounded(.down) / 120
        if peakSegment != heldPeak { heldPeak = peakSegment }
    }
    public func decay() {
        setLevel(max(0, level - 0.08), peak: 0)
    }
}

@MainActor
public final class AppAudioChannel: ObservableObject, Identifiable {
    public let id: String
    @Published public private(set) var app: AudioApp
    public let core: ConsoleChannel
    public var settings: ChannelSettings {
        get { core.settings }
        set { core.updateSettings(newValue) }
    }
    private var coreSubscription: AnyCancellable?
    private let defaults: UserDefaults
    public private(set) var restorationError: Error?
    public var isMuted: Bool {
        get { core.isMuted }
        set { core.setMuted(newValue) }
    }
    public var isSolo: Bool {
        get { core.isSolo }
        set { core.setSolo(newValue) }
    }
    @Published public internal(set) var isProcessing = false
    public let metrics = ChannelAudioMetrics()
    @Published public internal(set) var message = "LISTENING"
    public let input = PCMFeed()
    public let postEQ = PCMFeed()
    private var passiveCapture: (any AudioCapturing)?
    private let makeCapture: @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing
    private var needsProcessUpdate = false
    public let sourceDefinition: ApplicationInput
    private weak var activeSource: AudioSource?
    public private(set) var sampleRate: Double = 48_000

    public init(app: AudioApp, defaults: UserDefaults = .standard, core restoredCore: ConsoleChannel? = nil,
         nodeRegistry: NodeRegistry? = nil,
         makeCapture: @escaping @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing = {
             SystemAudioCapture(feed: $0, processes: $1)
         }) {
        self.defaults = defaults
        self.makeCapture = makeCapture
        self.id = app.id
        self.app = app
        var settings: ChannelSettings
        if let data = defaults.data(forKey: "channel.\(app.id)"),
           let saved = try? JSONDecoder().decode(ChannelSettings.self, from: data), saved.gains.count == 10 {
            settings = saved
        } else { settings = ChannelSettings() }
        settings.volume = min(1, max(0, settings.volume))
        settings.eqEnabled = true
        if let restoredCore { core = restoredCore }
        else if let data = defaults.data(forKey: "channel.nodes.\(app.id)") {
            do {
                let registry = try nodeRegistry ?? StandardNodeRegistry.make()
                let snapshot = try JSONDecoder().decode(NodeSnapshot.self, from: data)
                if snapshot.configurationVersion == 3, defaults.data(forKey: "backup.beforeFilterOnly.channel.nodes.\(app.id)") == nil {
                    defaults.set(data, forKey: "backup.beforeFilterOnly.channel.nodes.\(app.id)")
                }
                guard let restored = try registry.makeNode(from: snapshot) as? ConsoleChannel, restored.id == app.id else {
                    throw SnapshotError.incompatibleNode(app.id)
                }
                core = restored
            } catch {
                core = ConsoleChannel(id: app.id, settings: settings)
                restorationError = error
                message = "PROCESSOR RESTORE FAILED"
            }
        } else { core = ConsoleChannel(id: app.id, settings: settings) }
        sourceDefinition = ApplicationInput(app: app, feed: input)
        coreSubscription = core.changes.sink { [weak self] _ in
            self?.save()
            self?.objectWillChange.send()
        }
    }

    public func listen() {
        guard passiveCapture == nil, !isProcessing else { return }
        guard app.isPlaying else { message = "IDLE"; return }
        do {
            let capture = makeCapture(input, app.processes)
            try capture.start()
            passiveCapture = capture
            message = "LISTENING"
        } catch { message = "AUDIO ACCESS NEEDED" }
    }

    public var sourceBinding: AudioSourceBinding {
        AudioSourceBinding(model: sourceDefinition, destination: PortAddress(nodeID: core.id, portID: "input"))
    }

    public func prepareForProcessing() {
        passiveCapture?.stop()
        passiveCapture = nil
    }

    public func setProcessingSource(_ source: AudioSource?) {
        activeSource = source
        isProcessing = source?.state == .running
        if isProcessing { message = "LIVE" }
    }

    public func stopProcessing() {
        activeSource = nil
        isProcessing = false
        listen()
    }

    public func shutdown() {
        activeSource = nil
        passiveCapture?.stop()
        passiveCapture = nil
        isProcessing = false
    }

    public func update(app: AudioApp) {
        sourceDefinition.update(app)
        let changed = self.app.processes != app.processes
        if changed || self.app.isPlaying != app.isPlaying || self.app.name != app.name { self.app = app }
        if changed { needsProcessUpdate = true }
        if needsProcessUpdate {
            do {
                try passiveCapture?.setProcesses(app.processes)
                try activeSource?.synchronize()
                needsProcessUpdate = false
                if isProcessing { message = "LIVE" }
                else if passiveCapture != nil { message = "LISTENING" }
            } catch { message = "RECONNECT NEEDED" }
        }
        if !isProcessing {
            if app.isPlaying { listen() }
            else if passiveCapture != nil {
                passiveCapture?.stop()
                passiveCapture = nil
                message = "IDLE"
            }
        }
    }

    private func save() {
        guard restorationError == nil else { return }
        if let data = try? JSONEncoder().encode(NodeSnapshot(core)) { defaults.set(data, forKey: "channel.nodes.\(id)") }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "channel.\(id)") }
    }

    public func tick() {
        guard let frame = (isProcessing ? postEQ : input).snapshot(includeSamples: false) else {
            metrics.decay()
            return
        }
        sampleRate = frame.sampleRate
        let signal = SpectrumAnalyzer.meterLevel(frame.peak)
        metrics.setLevel(max(signal, metrics.level - 0.07), peak: signal)
    }
}
