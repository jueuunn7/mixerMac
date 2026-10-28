import Foundation

public struct ChannelSettings: Codable, Equatable {
    public var gains: [Float] = [Float](repeating: 0, count: 10)
    public var frequencies: [Float] = EQSettings.frequencies
    public var bandwidths: [Float] = [Float](repeating: 1, count: 10)
    public var trimDB: Float = 0
    public var volume: Float = 1
    public var pan: Float = 0
    public var width: Float = 1
    public var eqEnabled = true
    public var isMuted = false
    public var isSolo = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case gains, frequencies, bandwidths, trimDB, volume, pan, width, eqEnabled, isMuted, isSolo }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gains = try values.decode([Float].self, forKey: .gains)
        frequencies = try values.decodeIfPresent([Float].self, forKey: .frequencies) ?? EQSettings.frequencies
        bandwidths = try values.decodeIfPresent([Float].self, forKey: .bandwidths) ?? Array(repeating: 1, count: 10)
        if frequencies.count != 10 { frequencies = EQSettings.frequencies }
        if bandwidths.count != 10 { bandwidths = Array(repeating: 1, count: 10) }
        frequencies = frequencies.enumerated().map { $0.element.isFinite ? min(20_000, max(20, $0.element)) : EQSettings.frequencies[$0.offset] }
        bandwidths = bandwidths.map { $0.isFinite ? min(4, max(0.05, $0)) : 1 }
        trimDB = try values.decodeIfPresent(Float.self, forKey: .trimDB) ?? 0
        volume = try values.decode(Float.self, forKey: .volume)
        pan = PanBalance.clamped(try values.decodeIfPresent(Float.self, forKey: .pan) ?? 0)
        width = StereoWidth.clamped(try values.decodeIfPresent(Float.self, forKey: .width) ?? 1)
        eqEnabled = try values.decode(Bool.self, forKey: .eqEnabled)
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try values.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
    }

    public var eqSettings: EQSettings {
        EQSettings(gains: gains, frequencies: frequencies, bandwidths: bandwidths, gainDB: trimDB, enabled: eqEnabled)
    }
}
