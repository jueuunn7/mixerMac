import AppKit
import CoreAudio
import AudioToolbox
import mixerMacDSP
@preconcurrency import AVFAudio

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]
    var isPlaying: Bool
}

@MainActor
enum AudioAppDiscovery {
    static func processIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &ids) == noErr else { return [] }
        return ids
    }

    static func number(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    static func ownProcesses() -> [AudioObjectID] {
        processIDs().filter { number($0, selector: kAudioProcessPropertyPID) == UInt32(ProcessInfo.processInfo.processIdentifier) }
    }

    static func apps() -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var groups: [String: AudioApp] = [:]
        for object in processIDs() {
            let pid = pid_t(number(object, selector: kAudioProcessPropertyPID))
            guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let direct = NSRunningApplication(processIdentifier: pid)
            let bundle = AudioDevices.string(object, selector: kAudioProcessPropertyBundleID) ?? direct?.bundleIdentifier ?? ""
            // A system-wide routing host already contains other apps' mix.
            // Tapping it alongside those apps can duplicate the same audio.
            guard !bundle.hasPrefix("local.mixermac"), !bundle.hasPrefix("com.bitgapp.eqmac") else { continue }
            let app = running.first(where: { $0.processIdentifier == pid })
                ?? running.first(where: { candidate in
                    guard let id = candidate.bundleIdentifier else { return false }
                    return bundle == id || bundle.hasPrefix(id + ".")
                })
                ?? running.first(where: { candidate in
                    guard let root = candidate.bundleURL?.path, let path = direct?.bundleURL?.path else { return false }
                    return path.hasPrefix(root + "/")
                })
            guard let app, let id = app.bundleIdentifier,
                  !id.hasPrefix("local.mixermac"), !id.hasPrefix("com.bitgapp.eqmac") else { continue }
            let playing = number(object, selector: kAudioProcessPropertyIsRunningOutput) != 0
            if var group = groups[id] {
                group.processes.append(object)
                group.isPlaying = group.isPlaying || playing
                groups[id] = group
            } else {
                groups[id] = AudioApp(id: id, name: app.localizedName ?? bundle, icon: app.icon,
                                      processes: [object], isPlaying: playing)
            }
        }
        return groups.values.map { value in
            var value = value
            value.processes.sort()
            return value
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct AppChannelSettings: Codable, Equatable {
    var gains: [Float] = [Float](repeating: 0, count: 10)
    var frequencies: [Float] = AppAudioChannel.frequencies
    var bandwidths: [Float] = [Float](repeating: 1, count: 10)
    var trimDB: Float = 0
    var volume: Float = 1
    var pan: Float = 0
    var eqEnabled = true
    var isMuted = false
    var isSolo = false

    init() {}

    private enum CodingKeys: String, CodingKey { case gains, frequencies, bandwidths, trimDB, volume, pan, eqEnabled, isMuted, isSolo }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gains = try values.decode([Float].self, forKey: .gains)
        frequencies = try values.decodeIfPresent([Float].self, forKey: .frequencies) ?? AppAudioChannel.frequencies
        bandwidths = try values.decodeIfPresent([Float].self, forKey: .bandwidths) ?? Array(repeating: 1, count: 10)
        if frequencies.count != 10 { frequencies = AppAudioChannel.frequencies }
        if bandwidths.count != 10 { bandwidths = Array(repeating: 1, count: 10) }
        frequencies = frequencies.enumerated().map { $0.element.isFinite ? min(20_000, max(20, $0.element)) : AppAudioChannel.frequencies[$0.offset] }
        bandwidths = bandwidths.map { $0.isFinite ? min(4, max(0.05, $0)) : 1 }
        trimDB = try values.decodeIfPresent(Float.self, forKey: .trimDB) ?? 0
        volume = try values.decode(Float.self, forKey: .volume)
        pan = PanBalance.clamped(try values.decodeIfPresent(Float.self, forKey: .pan) ?? 0)
        eqEnabled = try values.decode(Bool.self, forKey: .eqEnabled)
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try values.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
    }

    /// Shared by playback and the response inspector so the plot queries the
    /// same Apple EQ, including overlapping bands and trim.
    func applyEQ(to eq: AVAudioUnitEQ) {
        eq.bypass = false
        eq.globalGain = trimDB
        for index in eq.bands.indices {
            eq.bands[index].filterType = .parametric
            eq.bands[index].frequency = frequencies[index]
            eq.bands[index].bandwidth = bandwidths[index]
            eq.bands[index].gain = gains[index]
            eq.bands[index].bypass = !eqEnabled
        }
    }
}

struct MeterPeakHold {
    private(set) var level: Float = 0
    private var holdUntil: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0

    mutating func update(_ input: Float, now: TimeInterval) {
        let input = min(1, max(0, input))
        let releaseTime = max(0, now - max(lastUpdate, holdUntil))
        if input > 0 && input >= level {
            level = input
            holdUntil = now + 1.5
        } else if releaseTime > 0 {
            level = max(input, level - Float(releaseTime) * 0.35)
        }
        lastUpdate = now
    }
}

@MainActor
final class ChannelAudioMetrics: ObservableObject {
    @Published var level: Float = 0
    @Published private(set) var heldPeak: Float = 0
    private var peakHold = MeterPeakHold()

    func setLevel(_ value: Float, peak: Float? = nil) {
        let quantized = (min(1, max(0, value)) * 120).rounded(.down) / 120
        if quantized != level { level = quantized }
        peakHold.update(peak ?? value, now: ProcessInfo.processInfo.systemUptime)
        let peakSegment = (peakHold.level * 120).rounded(.down) / 120
        if peakSegment != heldPeak { heldPeak = peakSegment }
    }
    func decay() {
        setLevel(max(0, level - 0.08), peak: 0)
    }
}

@MainActor
final class AppChannelProcessor {
    private var engine: AVAudioEngine?
    private var capture: SystemAudioCapture?
    private var bridge: DriverAudioBridge?
    let eq: AVAudioUnitEQ
    let levelControl = AVAudioUnitEQ(numberOfBands: 0)
    let masterEQ = AVAudioUnitEQ(numberOfBands: BusEQSettings.frequencies.count)
    private var outputTapInstalled = false

    init(numberOfBands: Int = 10) {
        eq = AVAudioUnitEQ(numberOfBands: numberOfBands)
        BusEQSettings.configure(masterEQ)
        for index in eq.bands.indices {
            let frequency = AppAudioChannel.frequencies[index]
            eq.bands[index].frequency = frequency
            eq.bands[index].filterType = .parametric
            eq.bands[index].bandwidth = 1
            eq.bands[index].bypass = false
        }
    }

    func start(app: AudioApp, output: OutputDevice, input: PCMFeed, postEQ: PCMFeed) throws {
        stop()
        let bridge = try DriverAudioBridge(inputFeed: input, rate: 48_000)
        self.bridge = bridge
        let capture = SystemAudioCapture(feed: input, processes: app.processes) { buffers, _ in
            mixerMacFIFOWrite(bridge.fifo, buffers)
        }
        self.capture = capture
        do {
            // Capture remains unmuted until the replacement playback engine is ready.
            try capture.start()
            try startPlayback(bridge: bridge, sampleRate: capture.sampleRate, output: output, postEQ: postEQ)
            try capture.setMutedWhenTapped(true)
        } catch { stop(); throw error }
    }

    private func startPlayback(bridge: DriverAudioBridge, sampleRate: Double, output: OutputDevice, postEQ: PCMFeed) throws {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                throw AudioDevices.RoutingError(operation: "Create app channel format", status: -1)
            }
            let source = AVAudioSourceNode(format: format) { _, _, count, buffers in
                bridge.render(count, buffers: buffers)
                return noErr
            }
            let engine = AVAudioEngine()
            self.engine = engine
            var deviceID = output.id
            guard let unit = engine.outputNode.audioUnit else {
                throw AudioDevices.RoutingError(operation: "Open app mixer output", status: -1)
            }
            try AudioDevices.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "Select mixer output")
            engine.attach(source)
            engine.attach(eq)
            engine.attach(levelControl)
            engine.attach(masterEQ)
            engine.connect(source, to: eq, format: format)
            engine.connect(eq, to: levelControl, format: format)
            engine.connect(levelControl, to: masterEQ, format: format)
            engine.connect(masterEQ, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            // Like the hardware channel meter, measure after trim/EQ and before
            // the channel fader. Mute does not hide input levels.
            eq.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in postEQ.push(buffer) }
            outputTapInstalled = true
            try engine.start()
    }

    func apply(_ settings: AppChannelSettings, audible: Bool, master: Float, sampleRate _: Double, masterEQ settingsEQ: BusEQSettings = BusEQSettings()) {
        settings.applyEQ(to: eq)
        bridge?.setPan(settings.pan)
        bridge?.setMasterPan(settingsEQ.pan)
        bridge?.setMasterWidth(settingsEQ.width)
        let gain = min(1, max(0, settings.volume)) * min(1, max(0, master))
        levelControl.bypass = false
        let decibels = 20 * log10(max(gain, 0.000_001))
        levelControl.globalGain = max(-96, min(36, decibels))
        settingsEQ.apply(to: masterEQ)
        engine?.mainMixerNode.outputVolume = audible && gain > 0 ? 1 : 0
    }

    func updateProcesses(_ processes: [AudioObjectID]) throws { try capture?.setProcesses(processes) }

    func stop() {
        engine?.mainMixerNode.outputVolume = 0
        // Destroying the muting tap always restores the app's native output.
        capture?.stop()
        capture = nil
        engine?.stop()
        if outputTapInstalled { eq.removeTap(onBus: 0) }
        outputTapInstalled = false
        if let engine {
            for node in engine.attachedNodes where !(node is AVAudioIONode) && !(node is AVAudioMixerNode) { engine.detach(node) }
        }
        engine = nil
        bridge = nil
    }
}

@MainActor
final class AppAudioChannel: ObservableObject, Identifiable {
    nonisolated static let frequencies: [Float] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    let id: String
    @Published var app: AudioApp
    @Published var settings: AppChannelSettings { didSet { save() } }
    private let defaults: UserDefaults
    var isMuted: Bool {
        get { settings.isMuted }
        set { settings.isMuted = newValue }
    }
    var isSolo: Bool {
        get { settings.isSolo }
        set { settings.isSolo = newValue }
    }
    @Published var isProcessing = false
    let metrics = ChannelAudioMetrics()
    @Published var message = "LISTENING"
    let input = PCMFeed()
    let postEQ = PCMFeed()
    private var passiveCapture: (any AudioCapturing)?
    private let makeCapture: @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing
    private var needsProcessUpdate = false
    let processor: AppChannelProcessor
    private(set) var sampleRate: Double = 48_000

    init(app: AudioApp, defaults: UserDefaults = .standard,
         makeCapture: @escaping @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing = {
             SystemAudioCapture(feed: $0, processes: $1)
         }) {
        self.defaults = defaults
        self.makeCapture = makeCapture
        self.id = app.id
        self.app = app
        processor = AppChannelProcessor()
        if let data = defaults.data(forKey: "channel.\(app.id)"),
           let saved = try? JSONDecoder().decode(AppChannelSettings.self, from: data), saved.gains.count == 10 {
            settings = saved
        } else { settings = AppChannelSettings() }
        settings.volume = min(1, max(0, settings.volume))
        settings.eqEnabled = true
    }

    func listen() {
        guard passiveCapture == nil, !isProcessing else { return }
        guard app.isPlaying else { message = "IDLE"; return }
        do {
            let capture = makeCapture(input, app.processes)
            try capture.start()
            passiveCapture = capture
            message = "LISTENING"
        } catch { message = "AUDIO ACCESS NEEDED" }
    }

    func process(output: OutputDevice) throws {
        passiveCapture?.stop()
        passiveCapture = nil
        try processor.start(app: app, output: output, input: input, postEQ: postEQ)
        isProcessing = true
        message = "LIVE"
    }

    func stopProcessing() {
        processor.stop()
        isProcessing = false
        listen()
    }

    func shutdown() {
        processor.stop()
        passiveCapture?.stop()
        passiveCapture = nil
        isProcessing = false
    }

    func update(app: AudioApp) {
        let changed = self.app.processes != app.processes
        if changed || self.app.isPlaying != app.isPlaying || self.app.name != app.name { self.app = app }
        if changed { needsProcessUpdate = true }
        if needsProcessUpdate {
            do {
                try passiveCapture?.setProcesses(app.processes)
                try processor.updateProcesses(app.processes)
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

    func setGain(_ gain: Float, index: Int) {
        guard gain.isFinite else { return }
        settings.gains[index] = min(24, max(-24, (gain * 10).rounded() / 10))
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "channel.\(id)") }
    }

    func tick() {
        guard let frame = (isProcessing ? postEQ : input).snapshot(includeSamples: false) else {
            metrics.decay()
            return
        }
        sampleRate = frame.sampleRate
        let signal = SpectrumAnalyzer.meterLevel(frame.peak)
        metrics.setLevel(max(signal, metrics.level - 0.07), peak: signal)
    }
}

@MainActor
final class MixerConsoleModel: ObservableObject {
    @Published var channels: [AppAudioChannel] = []
    @Published var outputs: [OutputDevice] = []
    @Published var outputID: UInt32 = 0
    @Published var isMixing = false
    @Published var isBusy = false
    @Published var masterEQ = BusEQSettings() { didSet { saveMasterEQ() } }
    @Published var status = "Detecting audio apps…"
    let masterMetrics = ChannelAudioMetrics()
    let masterLeftMetrics = ChannelAudioMetrics()
    let masterRightMetrics = ChannelAudioMetrics()
    let masterWaveform = MasterWaveformMetrics()
    let masterFeed = PCMFeed()
    private var masterCapture: (any AudioCapturing)?
    private let makeCapture: @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing
    private var ticks = 0
    private var masterProcessIDs: [AudioObjectID] = []
    private let preferences: ConsolePreferences
    private var preferredOutputUID: String?
    private var runRestoration: MixerRunRestoration
    private var isShuttingDown = false

    init(preferences: ConsolePreferences = ConsolePreferences(),
         makeCapture: @escaping @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing = {
             SystemAudioCapture(feed: $0, processes: $1)
         }) {
        self.preferences = preferences
        self.makeCapture = makeCapture
        preferredOutputUID = preferences.outputUID
        runRestoration = MixerRunRestoration(preferences: preferences)
        masterEQ = BusEQSettings.restored(defaults: preferences.defaults)
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
        if masterCapture == nil {
            let capture = makeCapture(masterFeed, nil)
            do {
                try capture.start()
                masterCapture = capture
            } catch { capture.stop() }
        }
        defer {
            if masterCapture == nil { status = "Allow system audio access, then click Refresh" }
        }
        let allDevices = AudioDevices.all()
        let devices = allDevices.filter { AudioDevices.isPhysicalOutput($0.id) }
        restoreOutputSelection(devices: devices, defaultOutputID: AudioDevices.defaultOutput())
        let detected = AudioAppDiscovery.apps()
        for app in detected {
            if let existing = channels.first(where: { $0.id == app.id }) { existing.update(app: app) }
            else {
                let channel = AppAudioChannel(app: app, defaults: preferences.defaults, makeCapture: makeCapture)
                channels.append(channel)
                channel.listen()
                if isMixing, let output = outputs.first(where: { $0.id == outputID }) {
                    do { try channel.process(output: output) }
                    catch { stopMixing(preservingRunningPreference: true); status = "Could not connect \(app.name): \(error.localizedDescription)" }
                }
            }
        }
        let ids = Set(detected.map(\.id))
        for removed in channels where !ids.contains(removed.id) { removed.shutdown() }
        if channels.contains(where: { !ids.contains($0.id) }) { channels.removeAll { !ids.contains($0.id) } }
        if !isMixing, runRestoration.takeStartupAttempt(
            hasOutput: outputs.contains(where: { $0.id == outputID }),
            hasApps: channels.contains(where: { !$0.app.processes.isEmpty })
        ) {
            startMixing()
            return
        }
        if isMixing {
            let own = AudioAppDiscovery.ownProcesses()
            if own != masterProcessIDs, !own.isEmpty {
                do { try masterCapture?.setProcesses(own); masterProcessIDs = own }
                catch { status = "Master meter could not reconnect" }
            }
            apply()
        } else if !channels.isEmpty {
            let text = "\(channels.count) audio apps detected · Power on to apply EQ, PAN and volume"
            if status != text { status = text }
        } else {
            let text = "Play audio in an app to add its channel automatically"
            if status != text { status = text }
        }
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
            for channel in channels { try channel.process(output: output) }
            isMixing = true
            apply()
            let own = AudioAppDiscovery.ownProcesses()
            if !own.isEmpty { try masterCapture?.setProcesses(own); masterProcessIDs = own }
            status = "Live · app EQ → \(output.name) · power off restores native app audio"
        } catch {
            for channel in channels { channel.stopProcessing() }
            isMixing = false
            apply()
            status = "Mixer could not start: \(error.localizedDescription)"
        }
    }

    func stopMixing(preservingRunningPreference: Bool = false) {
        if !preservingRunningPreference { runRestoration.explicitStop() }
        for channel in channels { channel.stopProcessing() }
        isMixing = false
        try? masterCapture?.setProcesses(nil)
        masterProcessIDs = []
        apply()
        status = "Mixer stopped · original app playback restored"
    }

    func saveMasterEQ() {
        if let data = try? JSONEncoder().encode(masterEQ) { preferences.defaults.set(data, forKey: "master.eq") }
    }

    func apply() {
        let anySolo = channels.contains(where: \.isSolo)
        for channel in channels {
            channel.processor.apply(channel.settings,
                audible: !channel.isMuted && (!anySolo || channel.isSolo), master: 1,
                sampleRate: channel.sampleRate, masterEQ: masterEQ)
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
