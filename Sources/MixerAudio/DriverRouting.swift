import MixerCore
import MixerStandardNodes
import Foundation
import CoreAudio
import AudioToolbox
import mixerMacDSP
@preconcurrency import AVFAudio

public struct OutputDevice: Identifiable, Hashable {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
}

public enum AudioDevices {
    public static let virtualUID = "mixerMacAudioDevice_UID"

    public static func all() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            guard let uid = string(device, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(device, selector: kAudioObjectPropertyName) else { return nil }
            return OutputDevice(id: device, name: name, uid: uid)
        }
    }

    public static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &bytes) == noErr && bytes > 0
    }

    public static func isPhysicalOutput(_ id: AudioObjectID) -> Bool {
        guard hasOutput(id) else { return false }
        // Some routing drivers advertise a hardware-like transport type.
        if let uid = string(id, selector: kAudioDevicePropertyDeviceUID), uid.lowercased().contains("eqmac") { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &transport) == noErr else { return false }
        return transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate
    }

    public static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UnsafeRawPointer? = nil
        var bytes = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &value) == noErr else { return nil }
        guard let value else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
    }

    public static func defaultOutput() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var bytes = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &device)
        return device
    }

    public static func setDefaultOutput(_ device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value), "Change playback device")
    }

    public static func sampleRate(_ device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 48_000.0
        var bytes = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &rate)
        return rate
    }

    public static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw RoutingError(operation: operation, status: status) }
    }

    public struct RoutingError: LocalizedError {
        let operation: String
        let status: OSStatus
        public var errorDescription: String? { "\(operation) failed (\(status))" }
    }
}

// The C FIFO provides SPSC synchronization. Only the input IOProc writes and only
// the source node reads. Both callbacks retain this owner until they are stopped.
final class DriverAudioBridge: @unchecked Sendable {
    let fifo: OpaquePointer
    let inputFeed: PCMFeed
    let rate: Double
    init(inputFeed: PCMFeed, rate: Double) throws {
        guard let fifo = mixerMacFIFOCreate() else {
            throw AudioDevices.RoutingError(operation: "Allocate audio bridge", status: -1)
        }
        self.fifo = fifo
        self.inputFeed = inputFeed
        self.rate = rate
    }
    deinit { mixerMacFIFODestroy(fifo) }
    func setPan(_ value: Float) { mixerMacFIFOSetPan(fifo, PanBalance.clamped(value)) }
    func setMasterPan(_ value: Float) { mixerMacFIFOSetMasterPan(fifo, PanBalance.clamped(value)) }
    func setMasterWidth(_ value: Float) { mixerMacFIFOSetMasterWidth(fifo, StereoWidth.clamped(value)) }
    func ingest(_ buffers: UnsafePointer<AudioBufferList>) {
        inputFeed.push(buffers, sampleRate: rate)
        mixerMacFIFOWrite(fifo, buffers)
    }
    nonisolated func write(_ buffers: UnsafePointer<AudioBufferList>, _ sampleRate: Double) {
        mixerMacFIFOWrite(fifo, buffers)
    }
    nonisolated func render(_ flags: UnsafeMutablePointer<ObjCBool>,
                           _ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: AVAudioFrameCount,
                           _ buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        mixerMacFIFORender(fifo, frames, buffers)
        return noErr
    }
    func render(_ frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) {
        mixerMacFIFORender(fifo, frames, buffers)
    }
}

@MainActor
final class DriverRouting {
    private var inputID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var previousOutput = AudioObjectID(kAudioObjectUnknown)
    private var outputTapInstalled = false

    func start(virtual: OutputDevice, output: OutputDevice, eq: AVAudioUnitEQ,
               inputFeed: PCMFeed, outputFeed: PCMFeed) throws {
        guard virtual.id != output.id, output.uid != AudioDevices.virtualUID else {
            throw AudioDevices.RoutingError(operation: "Choose headphones or speakers as output", status: -1)
        }
        stop()
        inputID = virtual.id
        previousOutput = AudioDevices.defaultOutput()
        if previousOutput == virtual.id { previousOutput = output.id }
        do {
            let rate = AudioDevices.sampleRate(virtual.id)
            let bridge = try DriverAudioBridge(inputFeed: inputFeed, rate: rate)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
                throw AudioDevices.RoutingError(operation: "Create stereo audio format", status: -1)
            }
            let source = AVAudioSourceNode(format: format, renderBlock: bridge.render)
            let engine = AVAudioEngine()
            self.engine = engine
            self.source = source
            var outputID = output.id
            guard let unit = engine.outputNode.audioUnit else {
                throw AudioDevices.RoutingError(operation: "Open output device", status: -1)
            }
            try AudioDevices.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &outputID, UInt32(MemoryLayout<AudioObjectID>.size)), "Select output device")
            engine.attach(source)
            engine.attach(eq)
            engine.connect(source, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                outputFeed.push(buffer)
            }
            outputTapInstalled = true
            try AudioDevices.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, virtual.id, nil) { _, input, _, _, _ in
                bridge.ingest(input)
            }, "Read virtual driver")
            inputFeed.reset()
            outputFeed.reset()
            try AudioDevices.check(AudioDeviceStart(virtual.id, ioProc), "Start virtual driver input")
            try engine.start()
            // Only redirect playback after both ends are running.
            try AudioDevices.setDefaultOutput(virtual.id)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        // Restore only if we still own the default selection; respect user changes.
        if inputID != kAudioObjectUnknown, AudioDevices.defaultOutput() == inputID,
           previousOutput != kAudioObjectUnknown, previousOutput != inputID {
            try? AudioDevices.setDefaultOutput(previousOutput)
        }
        if let ioProc { AudioDeviceStop(inputID, ioProc); AudioDeviceDestroyIOProcID(inputID, ioProc) }
        ioProc = nil
        engine?.stop()
        if outputTapInstalled { engine?.mainMixerNode.removeTap(onBus: 0) }
        outputTapInstalled = false
        if let engine {
            for node in engine.attachedNodes where !(node is AVAudioIONode) && !(node is AVAudioMixerNode) {
                engine.detach(node)
            }
        }
        source = nil
        engine = nil
        inputID = AudioObjectID(kAudioObjectUnknown)
        previousOutput = AudioObjectID(kAudioObjectUnknown)
    }
}
