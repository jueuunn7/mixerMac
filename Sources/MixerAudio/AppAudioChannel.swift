import AppKit
import Combine
import CoreAudio
import AudioToolbox
import MixerCore
import mixerMacDSP
@preconcurrency import AVFAudio

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
            let frequency = EQSettings.frequencies[index]
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

    func apply(_ settings: ChannelSettings, audible: Bool, master: Float, sampleRate _: Double, masterEQ settingsEQ: BusEQSettings = BusEQSettings()) {
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
public final class AppAudioChannel: ObservableObject, Identifiable {
    public let id: String
    @Published public private(set) var app: AudioApp
    public let core: Channel
    public var settings: ChannelSettings {
        get { core.settings }
        set { core.updateSettings(newValue) }
    }
    private var coreSubscription: AnyCancellable?
    private let defaults: UserDefaults
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
    let processor: AppChannelProcessor
    public private(set) var sampleRate: Double = 48_000

    public init(app: AudioApp, defaults: UserDefaults = .standard,
         makeCapture: @escaping @MainActor (PCMFeed, [AudioObjectID]?) -> any AudioCapturing = {
             SystemAudioCapture(feed: $0, processes: $1)
         }) {
        self.defaults = defaults
        self.makeCapture = makeCapture
        self.id = app.id
        self.app = app
        processor = AppChannelProcessor()
        var settings: ChannelSettings
        if let data = defaults.data(forKey: "channel.\(app.id)"),
           let saved = try? JSONDecoder().decode(ChannelSettings.self, from: data), saved.gains.count == 10 {
            settings = saved
        } else { settings = ChannelSettings() }
        settings.volume = min(1, max(0, settings.volume))
        settings.eqEnabled = true
        core = Channel(id: app.id, settings: settings)
        coreSubscription = core.changes.sink { [weak self] in
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

    public func process(output: OutputDevice) throws {
        passiveCapture?.stop()
        passiveCapture = nil
        try processor.start(app: app, output: output, input: input, postEQ: postEQ)
        isProcessing = true
        message = "LIVE"
    }

    public func stopProcessing() {
        processor.stop()
        isProcessing = false
        listen()
    }

    public func shutdown() {
        processor.stop()
        passiveCapture?.stop()
        passiveCapture = nil
        isProcessing = false
    }

    public func update(app: AudioApp) {
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

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "channel.\(id)") }
    }

    public func apply(audible: Bool, masterEQ: BusEQSettings) {
        processor.apply(settings, audible: audible, master: 1, sampleRate: sampleRate, masterEQ: masterEQ)
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
