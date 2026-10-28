import AudioToolbox
import mixerMacDSP
@preconcurrency import AVFAudio

private final class StereoRenderState: @unchecked Sendable {
    let dsp: OpaquePointer
    var buffer: AVAudioPCMBuffer?
    init() throws {
        guard let dsp = mixerMacStereoCreate() else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_MemFullError)) }
        self.dsp = dsp
    }
    deinit { mixerMacStereoDestroy(dsp) }
}

final class StereoAudioUnit: AUAudioUnit, @unchecked Sendable {
    static let component = AudioComponentDescription(componentType: kAudioUnitType_Effect,
        componentSubType: 0x6d737470, componentManufacturer: 0x6d786d63, componentFlags: 0, componentFlagsMask: 0)
    private let state: StereoRenderState
    override var shouldBypassEffect: Bool {
        didSet { mixerMacStereoSetBypassed(state.dsp, shouldBypassEffect ? 1 : 0) }
    }
    private var inputBusesStorage: AUAudioUnitBusArray!
    private var outputBusesStorage: AUAudioUnitBusArray!
    override var inputBusses: AUAudioUnitBusArray { inputBusesStorage }
    override var outputBusses: AUAudioUnitBusArray { outputBusesStorage }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        state = try StereoRenderState()
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBusesStorage = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputBusesStorage = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
    }

    override func allocateRenderResources() throws {
        let format = outputBusses[0].format
        guard format.channelCount == 2, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              inputBusses[0].format == format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesToRender) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        state.buffer = buffer
        try super.allocateRenderResources()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        state.buffer = nil
    }

    func set(pan: Float, width: Float) { mixerMacStereoSet(state.dsp, pan, width) }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = state
        return { flags, time, frames, _, output, _, pull in
            guard let pull, let buffer = state.buffer, frames <= buffer.frameCapacity else { return kAudioUnitErr_Uninitialized }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count == 2 else { return kAudioUnitErr_FormatNotSupported }
            let backing = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for index in buffers.indices where buffers[index].mData == nil {
                buffers[index].mData = backing[index].mData
                buffers[index].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
            }
            let status = pull(flags, time, frames, 0, output)
            guard status == noErr else { return status }
            mixerMacStereoProcess(state.dsp, frames, output)
            return noErr
        }
    }
}
