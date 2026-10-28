import AudioToolbox
import MixerCore
import mixerMacDSP
@preconcurrency import AVFAudio

@MainActor
public final class ApplicationInput: MixerNode {
    public static let sourceType = "macos.application-input"
    public private(set) var app: AudioApp
    public let feed: PCMFeed
    public init(app: AudioApp, feed: PCMFeed) {
        self.app = app
        self.feed = feed
        super.init(id: app.id + ".source", typeID: Self.sourceType, ports: [.stereoOutput])
    }
    public func update(_ app: AudioApp) { self.app = app }
}

@MainActor
private final class ApplicationAudioSource: AudioSource {
    let input: ApplicationInput
    private var capture: SystemAudioCapture?
    private var bridge: DriverAudioBridge?
    private var processes: [UInt32] = []

    init(_ input: ApplicationInput) { self.input = input; super.init(model: input) }

    override func prepareResources() throws -> AudioEndpoint {
        let bridge = try DriverAudioBridge(inputFeed: input.feed, rate: 48_000)
        self.bridge = bridge
        let capture = SystemAudioCapture(feed: input.feed, processes: input.app.processes) { buffers, _ in
            mixerMacFIFOWrite(bridge.fifo, buffers)
        }
        self.capture = capture
        try capture.start()
        processes = input.app.processes
        guard let format = AVAudioFormat(standardFormatWithSampleRate: capture.sampleRate, channels: 2) else {
            throw AudioSourceError.incompatibleSource(input.id)
        }
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            bridge.render(frames, buffers: buffers)
            return noErr
        }
        return AudioEndpoint(source)
    }

    override func activateResources() throws { try capture?.setMutedWhenTapped(true) }
    override func updateResources() throws {
        guard processes != input.app.processes else { return }
        try capture?.setProcesses(input.app.processes)
        processes = input.app.processes
    }
    override func releaseResources() {
        capture?.stop()
        capture = nil
        bridge = nil
        processes = []
    }
}

public enum ApplicationAudioSources {
    @MainActor
    public static func make() throws -> AudioSourceRegistry {
        let registry = AudioSourceRegistry()
        try registry.register(ApplicationInput.sourceType, nodeType: ApplicationInput.self) { ApplicationAudioSource($0) }
        return registry
    }
}
