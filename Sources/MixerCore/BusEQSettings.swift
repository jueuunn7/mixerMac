import Foundation

public struct BusEQSettings: Codable, Equatable {
    public static let frequencies = EQSettings.frequencies
    public static let labels = EQSettings.labels
    public var gains = [Float](repeating: 0, count: frequencies.count)
    public var bandFrequencies = Self.frequencies
    public var bandwidths = [Float](repeating: 1, count: frequencies.count)
    public var gainDB: Float = 0
    public var pan: Float = 0
    public var width: Float = 1
    // Retained for backend bypass tests; restored public settings always enable EQ.
    public var enabled = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case gains, bandFrequencies, bandwidths, gainDB, pan, width, enabled }

    public init(from decoder: Decoder) throws {
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

    private static func clampedGain(_ gain: Float) -> Float {
        gain.isFinite ? min(24, max(-24, gain)) : 0
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

    public var eqSettings: EQSettings {
        EQSettings(gains: gains, frequencies: bandFrequencies, bandwidths: bandwidths,
            gainDB: Self.clampedGain(gainDB), enabled: enabled)
    }
}
