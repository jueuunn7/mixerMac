import AudioToolbox
import mixerMacDSP
@preconcurrency import AVFAudio

private final class CrunchRenderState: @unchecked Sendable {
    let dsp: OpaquePointer
    var buffer: AVAudioPCMBuffer?
    var rate: Double = 48000
    init() throws {
        guard let dsp = mixerMacCrunchCreate() else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_MemFullError)) }
        self.dsp = dsp
    }
    deinit { mixerMacCrunchDestroy(dsp) }
}

final class CrunchAudioUnit: AUAudioUnit, @unchecked Sendable {
    static let component = AudioComponentDescription(componentType: kAudioUnitType_Effect,
        componentSubType: 0x6d63726e, componentManufacturer: 0x6d786d63, componentFlags: 0, componentFlagsMask: 0)
    private var amount: Float = 0
    private let state: CrunchRenderState
    override var shouldBypassEffect: Bool {
        didSet { mixerMacCrunchSet(state.dsp, amount, shouldBypassEffect ? 1 : 0) }
    }
    private var inputBusesStorage: AUAudioUnitBusArray!
    private var outputBusesStorage: AUAudioUnitBusArray!
    override var inputBusses: AUAudioUnitBusArray { inputBusesStorage }
    override var outputBusses: AUAudioUnitBusArray { outputBusesStorage }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        state = try CrunchRenderState()
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
        mixerMacCrunchReset(state.dsp)
        state.rate = format.sampleRate
        state.buffer = buffer
        try super.allocateRenderResources()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        state.buffer = nil
    }

    func set(amount: Float) { self.amount = amount; mixerMacCrunchSet(state.dsp, amount, shouldBypassEffect ? 1 : 0) }

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
            mixerMacCrunchProcess(state.dsp, frames, output, state.rate)
            return noErr
        }
    }
}
