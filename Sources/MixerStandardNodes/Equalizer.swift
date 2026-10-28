import MixerCore

public struct EQSettings: Equatable, Sendable {
    public static let frequencies: [Float] = [32, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let labels = ["32", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    public var gains: [Float]
    public var frequencies: [Float]
    public var bandwidths: [Float]
    public var gainDB: Float
    public var enabled: Bool

    public init(gains: [Float] = Array(repeating: 0, count: 10), frequencies: [Float] = Self.frequencies,
                bandwidths: [Float] = Array(repeating: 1, count: 10), gainDB: Float = 0, enabled: Bool = true) {
        self.gains = gains
        self.frequencies = frequencies
        self.bandwidths = bandwidths
        self.gainDB = gainDB
        self.enabled = enabled
    }
}

@MainActor
public final class EQBand {
    public let frequency: Parameter
    public let gain: Parameter
    public let bandwidth: Parameter

    init(frequency: Float, gain: Float, bandwidth: Float, defaultFrequency: Float) {
        self.frequency = Parameter(value: frequency, range: 20...20_000, defaultValue: defaultFrequency, unit: .hertz)
        self.gain = Parameter(value: gain, range: -24...24, defaultValue: 0, unit: .decibels)
        self.bandwidth = Parameter(value: bandwidth, range: 0.05...4, defaultValue: 1, unit: .octaves)
    }
}

@MainActor
public final class ParametricEQNode: MixerNode {
    public let bands: [EQBand]

    public init(id: String, settings: EQSettings = EQSettings()) {
        precondition(settings.gains.count == 10 && settings.frequencies.count == 10 && settings.bandwidths.count == 10)
        bands = (0..<10).map { index in
            EQBand(frequency: settings.frequencies[index], gain: settings.gains[index],
                bandwidth: settings.bandwidths[index], defaultFrequency: EQSettings.frequencies[index])
        }
        var parameters: [String: Parameter] = [:]
        for (index, band) in bands.enumerated() {
            parameters["band.\(index).frequency"] = band.frequency
            parameters["band.\(index).gain"] = band.gain
            parameters["band.\(index).bandwidth"] = band.bandwidth
        }
        super.init(id: id, typeID: StandardNodeType.parametricEQ, ports: [.stereoInput, .stereoOutput], parameters: parameters)
        setBypassed(!settings.enabled)
    }

    public func updateSettings(_ settings: EQSettings) {
        precondition(settings.gains.count == bands.count && settings.frequencies.count == bands.count
            && settings.bandwidths.count == bands.count)
        performUpdate {
            for index in bands.indices {
                bands[index].gain.setValue(settings.gains[index])
                bands[index].frequency.setValue(settings.frequencies[index])
                bands[index].bandwidth.setValue(settings.bandwidths[index])
            }
            setBypassed(!settings.enabled)
        }
    }
}

@MainActor
public final class Equalizer: ProcessingChain {
    public let gainStage: GainNode
    public let filter: ParametricEQNode
    public var gain: Parameter { gainStage.gain }
    public var bands: [EQBand] { filter.bands }
    public var enabled: Bool { !filter.isBypassed }

    public init(id: String, settings: EQSettings = EQSettings()) {
        gainStage = GainNode(id: id + ".gain", value: settings.gainDB)
        filter = ParametricEQNode(id: id + ".filter", settings: settings)
        super.init(id: id, typeID: "standard.equalizer", nodes: [gainStage, filter])
    }

    public override func validateProcessingNodes(_ nodes: [MixerNode]) throws {
        for required in [gainStage, filter] as [MixerNode] {
            guard nodes.contains(where: { $0 === required }) else { throw PresetError.requiredNodeRemoved(required.id) }
        }
    }

    public var settings: EQSettings {
        EQSettings(gains: bands.map { $0.gain.value }, frequencies: bands.map { $0.frequency.value },
            bandwidths: bands.map { $0.bandwidth.value }, gainDB: gain.value, enabled: enabled)
    }

    public func updateSettings(_ settings: EQSettings) {
        performUpdate {
            gain.setValue(settings.gainDB)
            filter.updateSettings(settings)
        }
    }
}
