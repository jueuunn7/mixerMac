import Foundation
import CoreAudio
import AudioToolbox

/// A private, unmuted process tap: observes playback without opening a microphone
/// or sending a second copy of the sound to the output device.
@available(macOS 14.2, *)
@MainActor
final class SystemAudioCapture {
    private let feed: PCMFeed
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private let processes: [AudioObjectID]?
    private let receiver: (@Sendable (UnsafePointer<AudioBufferList>, Double) -> Void)?
    private(set) var sampleRate: Double = 48_000

    init(feed: PCMFeed, processes: [AudioObjectID]? = nil,
         receiver: (@Sendable (UnsafePointer<AudioBufferList>, Double) -> Void)? = nil) {
        self.feed = feed
        self.processes = processes
        self.receiver = receiver
    }

    func start() throws {
        guard tapID == kAudioObjectUnknown else { return }
        do {
            let description = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) }
                ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            self.description = description
            description.name = "mixerMac System Audio Analyzer"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Create audio tap")

            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &formatSize, &format), "Read tap format")
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw CaptureError(operation: "Unsupported system audio format", code: -1)
            }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "mixerMac Private Analyzer",
                kAudioAggregateDeviceUIDKey: "local.mixermac.analysis.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "Create private analyzer")
            let rate = format.mSampleRate
            self.sampleRate = rate
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, nil) { [feed, receiver] _, input, _, _, _ in
                feed.push(input, sampleRate: rate)
                receiver?(input, rate)
            }, "Connect playback analyzer")
            feed.reset()
            try check(AudioDeviceStart(deviceID, ioProc), "Start playback analyzer")
        } catch {
            stop()
            throw error
        }
    }

    func setMutedWhenTapped(_ muted: Bool) throws {
        guard let description else { return }
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        try updateDescription(description)
    }

    func setProcesses(_ processes: [AudioObjectID]?) throws {
        guard let description else { return }
        description.processes = processes ?? []
        description.isExclusive = processes == nil
        try updateDescription(description)
    }

    private func updateDescription(_ description: CATapDescription) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = Unmanaged.passUnretained(description).toOpaque()
        try check(AudioObjectSetPropertyData(tapID, &address, 0, nil,
            UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &object), "Update app audio routing")
    }

    func stop() {
        if let ioProc, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        description = nil
        feed.reset()
    }

    private func check(_ code: OSStatus, _ operation: String) throws {
        guard code == noErr else { throw CaptureError(operation: operation, code: code) }
    }

    struct CaptureError: LocalizedError {
        let operation: String
        let code: OSStatus
        var errorDescription: String? {
            "\(operation) failed (\(code)). Allow mixerMac in System Settings → Privacy & Security → Screen & System Audio Recording, then retry."
        }
    }
}
