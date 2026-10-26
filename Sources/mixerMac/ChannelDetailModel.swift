import Foundation
import AudioToolbox
@preconcurrency import AVFAudio

/// AU NBandEQ returns dB (including globalGain) for property 52. Query a
/// separately initialized instance so inspecting a stopped channel never opens
/// a device or changes the running unit's render state.
@MainActor
final class ChannelEQResponse {
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private var rate: Double = 0

    func decibels(settings: AppChannelSettings, frequencies: [Double], sampleRate: Double) throws -> [Double] {
        if rate != sampleRate {
            AudioUnitUninitialize(eq.audioUnit)
            var newRate = sampleRate
            for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
                try AudioDevices.check(AudioUnitSetProperty(eq.audioUnit, kAudioUnitProperty_SampleRate,
                    scope, 0, &newRate, UInt32(MemoryLayout<Double>.size)), "Configure EQ response")
            }
            try AudioDevices.check(AudioUnitInitialize(eq.audioUnit), "Initialize EQ response")
            rate = sampleRate
        }
        settings.applyEQ(to: eq)
        precondition(frequencies.count < Int(kNumberOfResponseFrequencies))
        // NBandEQ needs the full fixed-size property buffer even when an
        // earlier negative-frequency sentinel ends the requested bins.
        var bins = (0..<Int(kNumberOfResponseFrequencies)).map { index in
            AudioUnitFrequencyResponseBin(mFrequency: index < frequencies.count ? frequencies[index] : -1, mMagnitude: 0)
        }
        var bytes = UInt32(bins.count * MemoryLayout<AudioUnitFrequencyResponseBin>.stride)
        let status = bins.withUnsafeMutableBytes {
            AudioUnitGetProperty(eq.audioUnit, kAudioUnitProperty_FrequencyResponse, kAudioUnitScope_Global, 0, $0.baseAddress!, &bytes)
        }
        try AudioDevices.check(status, "Read EQ response")
        return bins.prefix(frequencies.count).map(\.mMagnitude)
    }
}

@MainActor
final class ChannelDetailModel: ObservableObject {
    @Published private(set) var response: [Double] = []
    @Published private(set) var bandResponse: [Double] = []
    @Published private(set) var spectrum = [Float](repeating: -90, count: SpectrumAnalyzer.pointCount)
    @Published private(set) var history = [Double](repeating: -90, count: 100)
    @Published private(set) var peakDB: Double = -90
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var receivingAudio = false
    @Published private(set) var responseError: String?
    private let responseReader = ChannelEQResponse()
    private let analyzer = SpectrumAnalyzer()
    private var spectrumSmoother = SpectrumDisplaySmoother()
    private var sequence: UInt64?
    private var wasProcessing: Bool?
    private var lastSettings: AppChannelSettings?
    private var responseRate: Double = 0

    var upperFrequency: Double { min(20_000, sampleRate * 0.49) }
    var frequencyPoints: [Double] { (0..<256).map { 20 * pow(upperFrequency / 20, Double($0) / 255) } }

    func refreshResponse(settings: AppChannelSettings) {
        guard lastSettings != settings || responseRate != sampleRate else { return }
        do {
            let points = frequencyPoints + settings.frequencies.map(Double.init)
            let measured = try responseReader.decibels(settings: settings, frequencies: points, sampleRate: sampleRate)
            response = Array(measured.prefix(256))
            bandResponse = Array(measured.suffix(10))
            responseError = nil
            lastSettings = settings
            responseRate = sampleRate
        } catch {
            response = []
            bandResponse = []
            responseError = "EQ response unavailable: \(error.localizedDescription)"
        }
    }

    func tick(settings: AppChannelSettings, feed: PCMFeed, isProcessing: Bool) {
        if wasProcessing != isProcessing {
            sequence = nil
            wasProcessing = isProcessing
        }
        // Do not consume peaks: the console meter is an independent reader.
        if let frame = feed.snapshot(consumingPeaks: false), frame.sequence != sequence {
            sequence = frame.sequence
            sampleRate = frame.sampleRate
            spectrum = spectrumSmoother.update(analyzer.analyze(frame), smoothness: WaveformDisplaySettings.smoothness)
            let peak = max(frame.left.map { abs($0) }.max() ?? 0, frame.right.map { abs($0) }.max() ?? 0)
            peakDB = max(-90, 20 * log10(max(Double(peak), 0.000_001)))
            receivingAudio = true
        } else {
            spectrum = spectrumSmoother.update(Array(repeating: -90, count: SpectrumAnalyzer.pointCount), smoothness: WaveformDisplaySettings.smoothness)
            peakDB = max(-90, peakDB - 8)
            receivingAudio = false
        }
        history.removeFirst()
        history.append(peakDB)
        refreshResponse(settings: settings)
    }
}
