import Foundation
import Accelerate
import AudioToolbox
import mixerMacDSP
@preconcurrency import AVFAudio

struct PCMFrame: Sendable {
    let left: [Float]
    let right: [Float]
    let sampleRate: Double
    let peak: Float
    let leftPeak: Float
    let rightPeak: Float
    let sequence: UInt64
}

// Native storage makes capture callbacks bounded and allocation-free.
// The C side uses a nonblocking try flag; analysis packets may be dropped,
// but the separate playback FIFO is never delayed by graph drawing.
final class PCMFeed: @unchecked Sendable {
    static let capacity = 4096
    private let state: OpaquePointer

    init() {
        guard let state = mixerMacAnalysisCreate() else {
            preconditionFailure("Unable to allocate analysis storage")
        }
        self.state = state
    }

    deinit { mixerMacAnalysisDestroy(state) }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        mixerMacAnalysisPush(state, buffer.audioBufferList, buffer.format.sampleRate)
    }

    func push(_ input: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        mixerMacAnalysisPush(state, input, sampleRate)
    }

    func snapshot(includeSamples: Bool = true, consumingPeaks: Bool = true) -> PCMFrame? {
        var rate = 0.0
        var peak: Float = 0
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var sequence: UInt64 = 0
        if !includeSamples {
            guard mixerMacAnalysisRead(state, nil, nil, &rate, &peak, &leftPeak, &rightPeak, &sequence) != 0 else { return nil }
            return PCMFrame(left: [], right: [], sampleRate: rate, peak: peak, leftPeak: leftPeak, rightPeak: rightPeak, sequence: sequence)
        }
        var left = [Float](repeating: 0, count: Self.capacity)
        var right = [Float](repeating: 0, count: Self.capacity)
        let valid = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                consumingPeaks
                    ? mixerMacAnalysisRead(state, l.baseAddress, r.baseAddress, &rate, &peak, &leftPeak, &rightPeak, &sequence)
                    : mixerMacAnalysisPeek(state, l.baseAddress, r.baseAddress, &rate, &peak, &leftPeak, &rightPeak, &sequence)
            }
        }
        guard valid != 0 else { return nil }
        return PCMFrame(left: left, right: right, sampleRate: rate, peak: peak, leftPeak: leftPeak, rightPeak: rightPeak, sequence: sequence)
    }

    func reset() { mixerMacAnalysisReset(state) }
}

// A 4096-point Hann-windowed FFT, normalized to peak dBFS for a full-scale sine.
// Stereo power is averaged after FFT, so opposite-phase channels do not cancel.
final class SpectrumAnalyzer {
    static let pointCount = 128
    static let floorDB: Float = -90
    private let size = PCMFeed.capacity
    private let log2Size: vDSP_Length = 12
    private let setup: FFTSetup
    private let window: [Float]
    private let amplitudeScale: Float
    private var real = [Float](repeating: 0, count: PCMFeed.capacity)
    private var imaginary = [Float](repeating: 0, count: PCMFeed.capacity)
    private var power = [Float](repeating: 0, count: PCMFeed.capacity / 2 + 1)

    init() {
        guard let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Unable to allocate FFT setup")
        }
        self.setup = setup
        let window = (0..<PCMFeed.capacity).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(PCMFeed.capacity - 1)))
        }
        self.window = window
        amplitudeScale = 2 / window.reduce(0, +)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func analyze(_ frame: PCMFrame) -> [Float] {
        guard frame.left.count == size, frame.right.count == size, frame.sampleRate > 0 else {
            return [Float](repeating: Self.floorDB, count: Self.pointCount)
        }
        for index in power.indices { power[index] = 0 }
        for samples in [frame.left, frame.right] {
            for index in 0..<size {
                real[index] = samples[index] * window[index]
                imaginary[index] = 0
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                }
            }
            for bin in power.indices {
                power[bin] += (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) * 0.5
            }
        }
        let upper = min(20_000, frame.sampleRate * 0.49)
        let binWidth = frame.sampleRate / Double(size)
        return (0..<Self.pointCount).map { index in
            let lowerFrequency = 20 * pow(upper / 20, Double(index) / Double(Self.pointCount))
            let upperFrequency = 20 * pow(upper / 20, Double(index + 1) / Double(Self.pointCount))
            let first = max(1, min(power.count - 1, Int((lowerFrequency / binWidth).rounded())))
            let last = max(first, min(power.count - 1, Int((upperFrequency / binWidth).rounded())))
            let maxPower = power[first...last].max() ?? 0
            let amplitude = sqrt(maxPower) * amplitudeScale
            return max(Self.floorDB, 20 * log10(max(amplitude, 0.000_001)))
        }
    }

    static func meterLevel(_ peak: Float) -> Float {
        let decibels = 20 * log10(max(peak, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }
}
