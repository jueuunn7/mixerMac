@testable import MixerAudio
import MixerCore
import Testing
import Foundation
@preconcurrency import AVFAudio
@testable import mixerMac

struct AudioAnalysisTests {
    @Test func faderHasUnityAtTopAndNeverBoosts() {
        #expect(FaderScale.position(for: 1) == 1)
        #expect(FaderScale.gain(at: 1) == 1)
        #expect(FaderScale.gain(at: 0.5) == 0.25)
        #expect(FaderScale.gain(at: 0) == 0)
        #expect(FaderScale.gain(at: 2) == 1)
        #expect(FaderScale.position(for: 4) == 1)
        for position in stride(from: Float(0), through: 1, by: 0.05) {
            let gain = FaderScale.gain(at: position)
            #expect(gain >= 0 && gain <= 1)
            if position > 0.005 { #expect(abs(FaderScale.position(for: gain) - position) < 0.0001) }
        }
    }
    private func tone(amplitude: Float, frequency: Double = 1000, oppositePhase: Bool = false, rate: Double = 48_000, frames: Int = 4096) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<frames {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
            channels[0][index] = value
            channels[1][index] = oppositePhase ? -value : value
        }
        return buffer
    }

    @Test func silenceStaysAtFloor() throws {
        let feed = PCMFeed()
        #expect(feed.snapshot() == nil)
        feed.push(try tone(amplitude: 0))
        let frame = try #require(feed.snapshot())
        #expect(frame.peak == 0)
        #expect(SpectrumAnalyzer().analyze(frame).allSatisfy { $0 == -90 })
        feed.reset()
        #expect(feed.snapshot() == nil)
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func toneFrequencyAndAmplitude(rate: Double) throws {
        let feed = PCMFeed()
        feed.push(try tone(amplitude: 0.5, oppositePhase: true, rate: rate))
        let frame = try #require(feed.snapshot())
        let spectrum = SpectrumAnalyzer().analyze(frame)
        let maximum = try #require(spectrum.max())
        let index = try #require(spectrum.firstIndex(of: maximum))
        let frequency = 20 * pow(1000, (Double(index) + 0.5) / Double(spectrum.count))
        #expect(abs(frequency - 1000) < 80)
        #expect(maximum > -8 && maximum < -5.5)
        #expect(abs(frame.peak - 0.5) < 0.001)
    }

    @Test func quieterToneDropsBySixDecibels() throws {
        let feed = PCMFeed()
        let analyzer = SpectrumAnalyzer()
        feed.push(try tone(amplitude: 0.5))
        let loud = analyzer.analyze(try #require(feed.snapshot())).max() ?? -90
        feed.push(try tone(amplitude: 0.25))
        let quiet = analyzer.analyze(try #require(feed.snapshot())).max() ?? -90
        #expect(abs((loud - quiet) - 6.0206) < 0.05)
        #expect(SpectrumAnalyzer.meterLevel(0) == 0)
        #expect(SpectrumAnalyzer.meterLevel(1) == 1)
    }

    @Test func spectrumMeasuresAudioRenderedThroughEQ() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .parametric
        eq.bands[0].frequency = 1000
        eq.bands[0].bandwidth = 1
        eq.bands[0].gain = 6
        eq.bands[0].bypass = false
        let source = try tone(amplitude: 0.1)
        let format = source.format
        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(source, at: nil, options: .loops)
        player.play()
        let feed = PCMFeed()
        // Discard the initial filter transient; no hardware or microphone is opened.
        for _ in 0..<5 {
            let status = try engine.renderOffline(4096, to: rendered)
            #expect(status == .success)
        }
        feed.push(rendered)
        let frame = try #require(feed.snapshot())
        let maximum = try #require(SpectrumAnalyzer().analyze(frame).max())
        // A -20 dBFS tone boosted 6 dB peaks near -14 dBFS (Hann leakage <1.5 dB).
        #expect(maximum > -15.5 && maximum < -13.5)
        #expect(frame.peak > 0.19 && frame.peak < 0.21)
    }

    @Test(arguments: [false, true])
    func coreAudioBufferLayouts(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<4096 {
            let sample = Float(sin(2 * Double.pi * 1000 * Double(index) / 48_000)) * 0.25
            if interleaved {
                let data = try #require(buffers[0].mData).assumingMemoryBound(to: Float.self)
                data[index * 2] = sample
                data[index * 2 + 1] = -sample * 0.25
            } else {
                try #require(buffers[0].mData).assumingMemoryBound(to: Float.self)[index] = sample
                try #require(buffers[1].mData).assumingMemoryBound(to: Float.self)[index] = -sample * 0.25
            }
        }
        let feed = PCMFeed()
        feed.push(buffer.audioBufferList, sampleRate: 48_000)
        let frame = try #require(feed.snapshot())
        #expect(abs(frame.peak - 0.25) < 0.001)
        #expect(frame.left[12] == -frame.right[12] * 4)
        #expect(abs(frame.leftPeak - 0.25) < 0.001)
        #expect(abs(frame.rightPeak - 0.0625) < 0.001)
        let peakDB = try #require(SpectrumAnalyzer().analyze(frame).max())
        #expect(peakDB > -17 && peakDB < -14)
        feed.push(buffer.audioBufferList, sampleRate: 48_000)
        let meterOnly = try #require(feed.snapshot(includeSamples: false))
        #expect(meterOnly.left.isEmpty && meterOnly.right.isEmpty)
        #expect(abs(meterOnly.leftPeak - 0.25) < 0.001)
        #expect(abs(meterOnly.rightPeak - 0.0625) < 0.001)
    }

    @Test @MainActor func appEQChannelsDoNotAffectEachOther() throws {
        let first = AppChannelProcessor()
        let second = AppChannelProcessor()
        var cut = ChannelSettings()
        cut.gains[5] = -12 // Only app A cuts 1 kHz.
        first.apply(cut, audible: true, master: 1, sampleRate: 48_000)
        second.apply(ChannelSettings(), audible: true, master: 1, sampleRate: 48_000)

        func render(_ eq: AVAudioUnitEQ) throws -> Float {
            // An integer number of cycles avoids an artificial click at loop boundaries.
            let source = try tone(amplitude: 0.1, frequency: 48_000.0 * 85 / 4096)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.attach(eq)
            engine.connect(player, to: eq, format: source.format)
            engine.connect(eq, to: engine.mainMixerNode, format: source.format)
            try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: 4096)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 4096))
            try engine.start()
            defer { engine.stop(); engine.detach(eq) }
            player.scheduleBuffer(source, at: nil, options: .loops)
            player.play()
            for _ in 0..<5 { #expect(try engine.renderOffline(4096, to: buffer) == .success) }
            let feed = PCMFeed()
            feed.push(buffer)
            return try #require(feed.snapshot()).peak
        }
        let firstPeak = try render(first.eq)
        let secondPeak = try render(second.eq)
        #expect(abs(20 * log10(secondPeak / firstPeak) - 12) < 0.2)
        #expect(abs(secondPeak - 0.1) < 0.002)
    }

    @Test(arguments: [false, true]) @MainActor
    func faderAttenuationTrimAndEQRemainIndependent(eqEnabled: Bool) throws {
        let processor = AppChannelProcessor()
        var settings = ChannelSettings()
        settings.eqEnabled = eqEnabled
        settings.gains[5] = 6
        settings.trimDB = 3
        settings.volume = 0.5
        processor.apply(settings, audible: true, master: 1, sampleRate: 48_000)
        let source = try tone(amplitude: 0.1, frequency: 48_000.0 * 85 / 4096)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(processor.eq)
        engine.attach(processor.levelControl)
        engine.connect(player, to: processor.eq, format: source.format)
        engine.connect(processor.eq, to: processor.levelControl, format: source.format)
        engine.connect(processor.levelControl, to: engine.mainMixerNode, format: source.format)
        try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: 4096)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 4096))
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(source, at: nil, options: .loops)
        player.play()
        for _ in 0..<5 { #expect(try engine.renderOffline(4096, to: buffer) == .success) }
        let feed = PCMFeed()
        feed.push(buffer)
        let peak = try #require(feed.snapshot()).peak
        let expectedDB: Float = (eqEnabled ? 9 : 3) + 20 * log10(Float(0.5))
        #expect(abs(20 * log10(peak / 0.1) - expectedDB) < 0.05)
    }

    @Test func savedChannelsFromBeforeTrimKeepTheirSettings() throws {
        let oldSettings = Data(#"{"gains":[0,0,0,0,0,6,0,0,0,0],"volume":0.5,"eqEnabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(ChannelSettings.self, from: oldSettings)
        #expect(settings.trimDB == 0)
        #expect(settings.gains[5] == 6)
        #expect(settings.volume == 0.5)
        #expect(!settings.eqEnabled)
    }

    @Test(arguments: [0, 10]) @MainActor
    func channelEQOutputRetainsInputLevelWithFaderDown(bands: Int) throws {
        let processor = AppChannelProcessor(numberOfBands: bands)
        var settings = ChannelSettings()
        if bands == 0 { settings.gains = [Float](repeating: 12, count: 10) }
        settings.trimDB = 6
        settings.volume = 0.01
        processor.apply(settings, audible: true, master: 0.1, sampleRate: 48_000)
        let source = try tone(amplitude: 0.1, frequency: 48_000.0 * 85 / 4096)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(processor.eq)
        // Render exactly the EQ output used by the pre-fader meter tap.
        engine.connect(player, to: processor.eq, format: source.format)
        engine.connect(processor.eq, to: engine.mainMixerNode, format: source.format)
        try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: 4096)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: 4096))
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(source, at: nil, options: .loops)
        player.play()
        for _ in 0..<5 { #expect(try engine.renderOffline(4096, to: buffer) == .success) }
        let feed = PCMFeed()
        feed.push(buffer)
        let peak = try #require(feed.snapshot()).peak
        #expect(abs(20 * log10(peak / 0.1) - 6) < 0.05)
    }

    @Test func hardwareStyleMeterReferenceDoesNotMislabelSilence() {
        #expect(MixerMeterScale.decibels(for: 0) == -.infinity)
        #expect(abs(MixerMeterScale.decibels(for: SpectrumAnalyzer.meterLevel(pow(10, -14.0 / 20)))) < 0.001)
        #expect(MixerMeterScale.decibels(for: 1) == 14)
    }

    @Test(arguments: [true, false], Array(BusEQSettings.frequencies.indices)) @MainActor
    func masterEQProcessesOutputAndLeavesChannelMeterUnchanged(enabled: Bool, band: Int) throws {
        let processor = AppChannelProcessor()
        let secondProcessor = AppChannelProcessor()
        var master = BusEQSettings()
        master.enabled = enabled
        master.gains[band] = 6
        processor.apply(ChannelSettings(), audible: true, master: 1, sampleRate: 48_000, masterEQ: master)
        secondProcessor.apply(ChannelSettings(), audible: true, master: 1, sampleRate: 48_000, masterEQ: master)

        func render(_ processor: AppChannelProcessor, throughMaster: Bool) throws -> Float {
            // More cycles resolve the lowest bands. Whole cycles keep the loop seamless.
            let frames = 16384
            let frequency = (Double(BusEQSettings.frequencies[band]) * Double(frames) / 48_000).rounded() * 48_000 / Double(frames)
            let source = try tone(amplitude: 0.1, frequency: frequency, frames: frames)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.attach(processor.eq)
            engine.connect(player, to: processor.eq, format: source.format)
            if throughMaster {
                engine.attach(processor.levelControl)
                engine.attach(processor.masterEQ)
                engine.connect(processor.eq, to: processor.levelControl, format: source.format)
                engine.connect(processor.levelControl, to: processor.masterEQ, format: source.format)
                engine.connect(processor.masterEQ, to: engine.mainMixerNode, format: source.format)
            } else {
                engine.connect(processor.eq, to: engine.mainMixerNode, format: source.format)
            }
            let frameCount = AVAudioFrameCount(frames)
            try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: frameCount)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frameCount))
            try engine.start()
            defer {
                engine.stop()
                engine.detach(processor.eq)
                if throughMaster { engine.detach(processor.levelControl); engine.detach(processor.masterEQ) }
            }
            player.scheduleBuffer(source, at: nil, options: .loops)
            player.play()
            for _ in 0..<5 { #expect(try engine.renderOffline(frameCount, to: buffer) == .success) }
            let feed = PCMFeed()
            feed.push(buffer)
            return try #require(feed.snapshot()).peak
        }
        let output = try render(processor, throughMaster: true)
        let secondOutput = try render(secondProcessor, throughMaster: true)
        let channel = try render(processor, throughMaster: false)
        #expect(abs(20 * log10(output / 0.1) - (enabled ? 6 : 0)) < 0.15)
        #expect(abs(20 * log10(secondOutput / output)) < 0.01)
        #expect(abs(20 * log10(channel / 0.1)) < 0.05)
    }
}
