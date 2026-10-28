import Combine
import CoreAudio
@preconcurrency import AVFAudio
import MixerCore
import MixerStandardNodes

@MainActor
open class MixerSession: ObservableObject {
    public let core: ConsoleMixer
    private var coreSubscription: AnyCancellable?
    @Published public private(set) var channels: [AppAudioChannel] = [] {
        didSet {
            let currentIDs = Set(channels.map(\.id))
            core.replaceChannels(core.channels.filter { !currentIDs.contains($0.id) } + channels.map(\.core))
        }
    }
    @Published public private(set) var outputs: [OutputDevice] = []
    @Published public private(set) var outputID: UInt32 = 0
    @Published public private(set) var isMixing = false
    @Published public private(set) var isBusy = false
    public var masterEQ: BusEQSettings {
        get { core.master.settings }
        set { core.master.updateSettings(newValue) }
    }
    @Published public private(set) var status = "Detecting audio apps…"
    public let masterMetrics = ChannelAudioMetrics()
    public let masterLeftMetrics = ChannelAudioMetrics()
    public let masterRightMetrics = ChannelAudioMetrics()
    public let masterWaveform = MasterWaveformMetrics()
    public let masterFeed = PCMFeed()
    private var masterCapture: (any AudioCapturing)?
    private let makeCapture: @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing
    public let playback: AudioGraphPlayback
    private let discoverOwnProcesses: @MainActor () -> [AudioObjectID]
    private var masterCaptureError: String?
    private var routingError: String?
    private var mixingError: String?
    public private(set) var documentError: Error?
    private let nodeRegistry: NodeRegistry
    private var channelErrors: [String: String] = [:]
    private var ticks = 0
    private var masterProcessIDs: [AudioObjectID] = []
    private let preferences: ConsolePreferences
    private var preferredOutputUID: String?
    private var runRestoration: MixerRunRestoration
    private var isShuttingDown = false

    public init(preferences: ConsolePreferences = ConsolePreferences(),
         nodeRegistry: NodeRegistry? = nil,
         sources: AudioSourceRegistry? = nil,
         processors: AudioProcessorRegistry? = nil,
         audioOutput: (any AudioOutput)? = nil,
         discoverOwnProcesses: @escaping @MainActor () -> [AudioObjectID] = { AudioAppDiscovery.ownProcesses() },
         makeCapture: @escaping @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing = {
             SystemAudioCapture(feed: $0, processes: $1)
         }) {
        self.preferences = preferences
        self.makeCapture = makeCapture
        self.discoverOwnProcesses = discoverOwnProcesses
        preferredOutputUID = preferences.outputUID
        runRestoration = MixerRunRestoration(preferences: preferences)
        do { self.nodeRegistry = try nodeRegistry ?? StandardNodeRegistry.make() }
        catch { preconditionFailure("Invalid built-in node registrations: \(error)") }
        if let data = preferences.defaults.data(forKey: "mixer.graph.v1") {
            do {
                let snapshot = try JSONDecoder().decode(GraphSnapshot.self, from: data)
                let graph = AudioGraph()
                try self.nodeRegistry.restore(snapshot, into: graph)
                guard let master = graph.nodes.first(where: { $0.id == "master" }) as? ConsoleBus else {
                    throw SnapshotError.incompatibleNode("master")
                }
                let nodes = graph.nodes
                let connections = graph.connections
                try graph.replace(nodes: [], connections: [])
                let restored = ConsoleMixer(master: master, channels: nodes.compactMap { $0 as? Channel })
                try restored.graph.replace(nodes: nodes, connections: connections)
                core = restored
            } catch {
                core = ConsoleMixer(masterSettings: BusEQSettings.restored(defaults: preferences.defaults))
                documentError = error
            }
        } else { core = ConsoleMixer(masterSettings: BusEQSettings.restored(defaults: preferences.defaults)) }
        do {
            playback = AudioGraphPlayback(graph: core.graph, destination: PortAddress(nodeID: core.master.id, portID: "output"),
                output: audioOutput ?? DeviceAudioOutput(), sources: try sources ?? ApplicationAudioSources.make(),
                processors: try processors ?? StandardAudioProcessors.make(),
                format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        } catch { preconditionFailure("Invalid built-in audio registrations: \(error)") }
        coreSubscription = core.changes.sink { [weak self] change in
            guard let self else { return }
            self.objectWillChange.send()
            if change == .master { self.saveMasterEQ() }
            self.saveGraph()
            self.apply()
        }
    }

    public func selectOutput(_ id: UInt32) {
        guard !isMixing, let output = outputs.first(where: { $0.id == id }) else { return }
        outputID = id
        preferredOutputUID = output.uid
        preferences.saveOutputUID(output.uid)
    }

    public func start() {
        guard !isShuttingDown, masterCapture == nil else { return }
        refresh()
    }

    public func refresh() {
        guard !isShuttingDown else { return }
        let devices = AudioDevices.all().filter { AudioDevices.isPhysicalOutput($0.id) }
        refresh(apps: AudioAppDiscovery.apps(), devices: devices, defaultOutputID: AudioDevices.defaultOutput())
    }

    public func refresh(apps: [AudioApp], devices: [OutputDevice], defaultOutputID: UInt32) {
        guard !isShuttingDown else { return }
        if masterCapture == nil {
            let capture = makeCapture(masterFeed, nil)
            do {
                try capture.start()
                masterCapture = capture
                masterCaptureError = nil
            } catch {
                capture.stop()
                masterCaptureError = "Allow system audio access, then click Refresh"
            }
        }
        defer { updateStatus() }
        restoreOutputSelection(devices: devices, defaultOutputID: defaultOutputID)
        for app in apps {
            let channel: AppAudioChannel
            if let existing = channels.first(where: { $0.id == app.id }) {
                channel = existing
                channel.update(app: app)
            } else {
                channel = AppAudioChannel(app: app, defaults: preferences.defaults,
                    core: core.channels.first(where: { $0.id == app.id }) as? ConsoleChannel,
                    nodeRegistry: nodeRegistry, makeCapture: makeCapture)
                if let error = channel.restorationError { documentError = error }
                channels.append(channel)
                channel.listen()
            }
            if isMixing, !channel.isProcessing {
                do {
                    if let error = channel.restorationError { throw error }
                    channel.prepareForProcessing()
                    try playback.connect(channel.sourceBinding, feeds: channelFeeds)
                    channel.setProcessingSource(playback.source(id: channel.sourceDefinition.id))
                    channelErrors.removeValue(forKey: channel.id)
                } catch {
                    channel.stopProcessing()
                    channelErrors[channel.id] = "Could not connect \(app.name): \(error.localizedDescription)"
                }
            }
        }
        let ids = Set(apps.map(\.id))
        for removed in channels where !ids.contains(removed.id) { removed.shutdown() }
        if channels.contains(where: { !ids.contains($0.id) }) { channels.removeAll { !ids.contains($0.id) } }
        channelErrors = channelErrors.filter { ids.contains($0.key) }
        if !isMixing, runRestoration.takeStartupAttempt(
            hasOutput: outputs.contains(where: { $0.id == outputID }),
            hasApps: channels.contains(where: { !$0.app.processes.isEmpty })
        ) {
            startMixing()
            return
        }
        updateMasterCaptureRouting()
        if isMixing { apply() }
    }

    /// `devices` has already been restricted to physical outputs by discovery.
    public func restoreOutputSelection(devices: [OutputDevice], defaultOutputID: UInt32) {
        if outputs != devices { outputs = devices }
        if !devices.contains(where: { $0.id == outputID }) {
            if isMixing {
                stopMixing(preservingRunningPreference: true)
                runRestoration.waitForAvailability()
            }
            outputID = devices.first(where: { $0.uid == preferredOutputUID })?.id
                ?? devices.first(where: { $0.id == defaultOutputID })?.id ?? devices.first?.id ?? 0
        }
    }

    public func toggleMixing() {
        if isMixing { stopMixing(); return }
        guard !isBusy, !isShuttingDown else { return }
        runRestoration.explicitStart()
        guard channels.contains(where: { !$0.app.processes.isEmpty }),
              outputs.contains(where: { $0.id == outputID }) else {
            runRestoration.waitForAvailability()
            return
        }
        startMixing()
    }

    private func startMixing() {
        guard documentError == nil, !isBusy, !isShuttingDown, !channels.isEmpty,
              let output = outputs.first(where: { $0.id == outputID }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            for channel in channels {
                if let error = channel.restorationError { throw error }
                channel.prepareForProcessing()
            }
            try playback.start(device: output, bindings: channels.map(\.sourceBinding), feeds: channelFeeds)
            for channel in channels { channel.setProcessingSource(playback.source(id: channel.sourceDefinition.id)) }
            isMixing = true
            mixingError = nil
            channelErrors.removeAll()
            apply()
        } catch {
            playback.stop()
            for channel in channels { channel.stopProcessing() }
            isMixing = false
            apply()
            mixingError = "Mixer could not start: \(error.localizedDescription)"
            updateStatus()
            return
        }
        updateMasterCaptureRouting()
        updateStatus()
    }

    public func stopMixing(preservingRunningPreference: Bool = false) {
        if !preservingRunningPreference { runRestoration.explicitStop() }
        playback.stop()
        for channel in channels { channel.stopProcessing() }
        isMixing = false
        mixingError = nil
        routingError = nil
        channelErrors.removeAll()
        updateMasterCaptureRouting()
        apply()
        updateStatus()
    }

    private func updateMasterCaptureRouting() {
        guard let masterCapture else { return }
        let own = isMixing ? discoverOwnProcesses() : []
        guard !isMixing || !own.isEmpty else { return }
        guard own != masterProcessIDs else {
            masterCaptureError = nil
            return
        }
        do {
            try masterCapture.setProcesses(isMixing ? own : nil)
            masterProcessIDs = own
            masterCaptureError = nil
        } catch { masterCaptureError = "Master meter could not reconnect" }
    }

    private func updateStatus() {
        let errors = [documentError.map { "Could not restore mixer: \($0.localizedDescription)" }, mixingError, routingError, masterCaptureError].compactMap { $0 }
            + channels.compactMap { channelErrors[$0.id] }
        let text: String
        if !errors.isEmpty {
            text = errors.joined(separator: " · ")
        } else if isMixing, let output = outputs.first(where: { $0.id == outputID }) {
            text = "Live · app EQ → \(output.name) · power off restores native app audio"
        } else if !channels.isEmpty {
            text = "\(channels.count) audio apps detected · Power on to apply EQ, PAN and volume"
        } else {
            text = "Play audio in an app to add its channel automatically"
        }
        if status != text { status = text }
    }

    private func saveGraph() {
        guard documentError == nil else { return }
        do {
            let data = try JSONEncoder().encode(GraphSnapshot(core.graph))
            preferences.defaults.set(data, forKey: "mixer.graph.v1")
        } catch {
            documentError = error
            updateStatus()
        }
    }

    private func saveMasterEQ() {
        if let data = try? JSONEncoder().encode(masterEQ) { preferences.defaults.set(data, forKey: "master.eq") }
    }

    private var channelFeeds: [PortAddress: PCMFeed] {
        Dictionary(uniqueKeysWithValues: channels.map {
            (PortAddress(nodeID: $0.core.equalizer.id, portID: "output"), $0.postEQ)
        })
    }

    private func apply() {
        defer {
            if isMixing && !playback.isRunning {
                isMixing = false
                for channel in channels { channel.stopProcessing() }
                updateMasterCaptureRouting()
                updateStatus()
            }
        }
        do {
            try playback.apply(feeds: channelFeeds, activeSourceIDs: Set(channels.map { $0.sourceDefinition.id }))
            if routingError != nil { routingError = nil; updateStatus() }
        }
        catch {
            routingError = "Could not update mixer routing: \(error.localizedDescription)"
            updateStatus()
        }
    }

    public func tick(updateMeters: Bool) {
        ticks += 1
        if ticks % 30 == 0 { refresh() }
        // Keep audio routing alive while hidden; update meters only while visible.
        guard updateMeters else { return }
        for channel in channels { channel.tick() }
        masterWaveform.update(feed: masterFeed, enabled: isMixing)
        guard let frame = masterFeed.snapshot(includeSamples: false) else {
            masterMetrics.decay(); masterLeftMetrics.decay(); masterRightMetrics.decay()
            return
        }
        let signal = SpectrumAnalyzer.meterLevel(frame.peak)
        masterMetrics.setLevel(max(signal, masterMetrics.level - 0.07), peak: signal)
        let left = SpectrumAnalyzer.meterLevel(frame.leftPeak)
        let right = SpectrumAnalyzer.meterLevel(frame.rightPeak)
        masterLeftMetrics.setLevel(max(left, masterLeftMetrics.level - 0.07), peak: left)
        masterRightMetrics.setLevel(max(right, masterRightMetrics.level - 0.07), peak: right)
    }

    public func shutdown() {
        isShuttingDown = true
        runRestoration.shutdown()
        playback.stop()
        for channel in channels { channel.shutdown() }
        masterCapture?.stop()
        masterCapture = nil
        isMixing = false
    }
}
