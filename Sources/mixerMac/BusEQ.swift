import Foundation
@preconcurrency import AVFAudio

struct BusEQSettings: Codable, Equatable {
    static let frequencies: [Float] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    var gains = [Float](repeating: 0, count: frequencies.count)
    var bandFrequencies = Self.frequencies
    var bandwidths = [Float](repeating: 1, count: frequencies.count)
    var gainDB: Float = 0
    var pan: Float = 0
    var width: Float = 1
    // Retained for backend bypass tests; restored public settings always enable EQ.
    var enabled = true

    init() {}

    private enum CodingKeys: String, CodingKey { case gains, bandFrequencies, bandwidths, gainDB, pan, width, enabled }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try values.decode([Float].self, forKey: .gains)
        switch saved.count {
        case Self.frequencies.count:
            gains = saved.map(Self.clampedGain)
        case 4:
            gains = Self.migrateFourBands(saved.map(Self.clampedGain))
        default:
            throw DecodingError.dataCorruptedError(forKey: .gains, in: values,
                debugDescription: "Master EQ requires four legacy or ten current gains.")
        }
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        gainDB = Self.clampedGain(try values.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0)
        pan = PanBalance.clamped(try values.decodeIfPresent(Float.self, forKey: .pan) ?? 0)
        width = StereoWidth.clamped(try values.decodeIfPresent(Float.self, forKey: .width) ?? 1)
        let savedFrequencies = try values.decodeIfPresent([Float].self, forKey: .bandFrequencies)
        let savedWidths = try values.decodeIfPresent([Float].self, forKey: .bandwidths)
        if let savedFrequencies, savedFrequencies.count == 10 {
            bandFrequencies = savedFrequencies.enumerated().map { $0.element.isFinite ? min(20_000, max(20, $0.element)) : Self.frequencies[$0.offset] }
        }
        if let savedWidths, savedWidths.count == 10 {
            bandwidths = savedWidths.map { $0.isFinite ? min(4, max(0.05, $0)) : 1 }
        }
    }

    static func restored(defaults: UserDefaults = .standard) -> BusEQSettings {
        guard let data = defaults.data(forKey: "master.eq"),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        saved.enabled = true
        return saved
    }

    private static func clampedGain(_ gain: Float) -> Float {
        gain.isFinite ? min(24, max(-24, gain)) : 0
    }

    var detailSettings: AppChannelSettings {
        get {
            var settings = AppChannelSettings()
            settings.gains = gains
            settings.frequencies = bandFrequencies
            settings.bandwidths = bandwidths
            settings.trimDB = Self.clampedGain(gainDB)
            settings.pan = pan
            settings.eqEnabled = enabled
            return settings
        }
        set {
            gains = newValue.gains.map(Self.clampedGain)
            bandFrequencies = newValue.frequencies
            bandwidths = newValue.bandwidths
            gainDB = Self.clampedGain(newValue.trimDB)
            pan = PanBalance.clamped(newValue.pan)
            enabled = true
        }
    }

    /// Approximate the old tonal curve, rather than dropping its settings or
    /// treating the old array indices as the first four graphic EQ bands.
    /// Extend the 180 Hz low-shelf gain to 31.5/63/125 Hz and the 3 kHz
    /// high-shelf gain to 4/8/16 kHz. Interpolate the remaining centers in
    /// log-frequency between the old 180/350/1100/3000 Hz gain anchors.
    /// This preserves broad tonal intent, not the exact old filter response:
    /// all ten new filters are one-octave parametric bands, like the app EQ.
    private static func migrateFourBands(_ saved: [Float]) -> [Float] {
        let legacy: [Float] = [180, 350, 1100, 3000]
        return frequencies.map { frequency in
            if frequency <= legacy[0] { return saved[0] }
            if frequency >= legacy[3] { return saved[3] }
            let upper = legacy.firstIndex(where: { $0 >= frequency })!
            let lower = upper - 1
            let fraction = log(frequency / legacy[lower]) / log(legacy[upper] / legacy[lower])
            return saved[lower] + (saved[upper] - saved[lower]) * fraction
        }
    }

    static func configure(_ eq: AVAudioUnitEQ) {
        precondition(eq.bands.count == frequencies.count, "Master EQ must have ten bands")
        for index in eq.bands.indices {
            eq.bands[index].frequency = frequencies[index]
            eq.bands[index].bandwidth = 1
            eq.bands[index].filterType = .parametric
            eq.bands[index].bypass = false
        }
    }

    func apply(to eq: AVAudioUnitEQ) {
        precondition(eq.bands.count == Self.frequencies.count && gains.count == Self.frequencies.count,
                     "Master EQ must have ten bands and ten gains")
        for index in eq.bands.indices {
            eq.bands[index].gain = Self.clampedGain(gains[index])
            eq.bands[index].frequency = bandFrequencies[index]
            eq.bands[index].bandwidth = bandwidths[index]
        }
        // No automatic headroom: a boost remains a boost in the rendered output.
        eq.globalGain = Self.clampedGain(gainDB)
        eq.bypass = !enabled
    }
}
