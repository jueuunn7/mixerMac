import AppKit
import Combine
import CoreAudio
import MixerCore
import MixerAudio

@MainActor
final class MixerConsoleModel: ObservableObject {
    let core: Mixer
    private var coreSubscription: AnyCancellable?
    @Published private(set) var channels: [AppAudioChannel] = [] {
        didSet { core.replaceChannels(channels.map(\.core)) }
    }
    @Published private(set) var outputs: [OutputDevice] = []
    @Published private(set) var outputID: UInt32 = 0
    @Published private(set) var isMixing = false
    @Published private(set) var isBusy = false
    var masterEQ: BusEQSettings {
        get { core.master.settings }
        set { core.master.updateSettings(newValue) }
    }
    @Published private(set) var status = "Detecting audio apps…"
    let masterMetrics = ChannelAudioMetrics()
    let masterLeftMetrics = ChannelAudioMetrics()
    let masterRightMetrics = ChannelAudioMetrics()
    let masterWaveform = MasterWaveformMetrics()
    let masterFeed = PCMFeed()
    private var masterCapture: (any AudioCapturing)?
    private let makeCapture: @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing
    private let processChannel: @MainActor (AppAudioChannel, OutputDevice) throws -> Void
    private let discoverOwnProcesses: @MainActor () -> [AudioObjectID]
    private var masterCaptureError: String?
    private var mixingError: String?
    private var channelErrors: [String: String] = [:]
    private var ticks = 0
    private var masterProcessIDs: [AudioObjectID] = []
    private let preferences: ConsolePreferences
    private var preferredOutputUID: String?
    private var runRestoration: MixerRunRestoration
    private var isShuttingDown = false

    init(preferences: ConsolePreferences = ConsolePreferences(),
         processChannel: @escaping @MainActor (AppAudioChannel, OutputDevice) throws -> Void = {
             try $0.process(output: $1)
         },
         discoverOwnProcesses: @escaping @MainActor () -> [AudioObjectID] = { AudioAppDiscovery.ownProcesses() },
         makeCapture: @escaping @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing = {
             SystemAudioCapture(feed: $0, processes: $1)
         }) {
        self.preferences = preferences
        self.makeCapture = makeCapture
        self.processChannel = processChannel
        self.discoverOwnProcesses = discoverOwnProcesses
        preferredOutputUID = preferences.outputUID
        runRestoration = MixerRunRestoration(preferences: preferences)
        core = Mixer(masterSettings: BusEQSettings.restored(defaults: preferences.defaults))
        coreSubscription = core.changes.sink { [weak self] change in
            guard let self else { return }
            self.objectWillChange.send()
            if change == .master { self.saveMasterEQ() }
            self.apply()
        }
    }

    func selectOutput(_ id: UInt32) {
        guard !isMixing, let output = outputs.first(where: { $0.id == id }) else { return }
        outputID = id
        preferredOutputUID = output.uid
        preferences.saveOutputUID(output.uid)
    }

    func start() {
        guard !isShuttingDown, masterCapture == nil else { return }
        refresh()
    }

    func refresh() {
        guard !isShuttingDown else { return }
        let devices = AudioDevices.all().filter { AudioDevices.isPhysicalOutput($0.id) }
        refresh(apps: AudioAppDiscovery.apps(), devices: devices, defaultOutputID: AudioDevices.defaultOutput())
    }

    func refresh(apps: [AudioApp], devices: [OutputDevice], defaultOutputID: UInt32) {
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
                channel = AppAudioChannel(app: app, defaults: preferences.defaults, makeCapture: makeCapture)
                channels.append(channel)
                channel.listen()
            }
            if isMixing, !channel.isProcessing, let output = outputs.first(where: { $0.id == outputID }) {
                do {
                    try processChannel(channel, output)
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
    func restoreOutputSelection(devices: [OutputDevice], defaultOutputID: UInt32) {
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

    func toggleMixing() {
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
        guard !isBusy, !isShuttingDown, !channels.isEmpty,
              let output = outputs.first(where: { $0.id == outputID }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            for channel in channels { try processChannel(channel, output) }
            isMixing = true
            mixingError = nil
            channelErrors.removeAll()
            apply()
        } catch {
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

    func stopMixing(preservingRunningPreference: Bool = false) {
        if !preservingRunningPreference { runRestoration.explicitStop() }
        for channel in channels { channel.stopProcessing() }
        isMixing = false
        mixingError = nil
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
        let errors = [mixingError, masterCaptureError].compactMap { $0 }
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

    private func saveMasterEQ() {
        if let data = try? JSONEncoder().encode(masterEQ) { preferences.defaults.set(data, forKey: "master.eq") }
    }

    private func apply() {
        let audible = core.audibleChannelIDs
        for channel in channels {
            channel.apply(audible: audible.contains(channel.id), masterEQ: masterEQ)
        }
    }

    func tick() {
        ticks += 1
        if ticks % 30 == 0 { refresh() }
        // Keep audio routing alive while hidden; update meters only while visible.
        guard NSApp.isActive || NSApp.windows.contains(where: { $0.occlusionState.contains(.visible) && !$0.isMiniaturized }) else { return }
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

    func shutdown() {
        isShuttingDown = true
        runRestoration.shutdown()
        for channel in channels { channel.shutdown() }
        masterCapture?.stop()
        masterCapture = nil
        isMixing = false
    }
}
