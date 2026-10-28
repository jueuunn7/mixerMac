import Combine

public struct EQSettings: Equatable, Sendable {
    public static let frequencies: [Float] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let labels = ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
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
public final class Equalizer {
    public let gain: Parameter
    public let bands: [EQBand]
    public private(set) var enabled: Bool
    private let changed = PassthroughSubject<Void, Never>()
    public var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    private var subscription: AnyCancellable?
    private var updating = false

    public init(settings: EQSettings = EQSettings()) {
        precondition(settings.gains.count == 10 && settings.frequencies.count == 10 && settings.bandwidths.count == 10)
        gain = Parameter(value: settings.gainDB, range: -24...24, defaultValue: 0, unit: .decibels)
        bands = (0..<10).map { index in
            EQBand(frequency: settings.frequencies[index], gain: settings.gains[index],
                bandwidth: settings.bandwidths[index], defaultFrequency: EQSettings.frequencies[index])
        }
        enabled = settings.enabled
        let parameters = [gain] + bands.flatMap { [$0.frequency, $0.gain, $0.bandwidth] }
        subscription = Publishers.MergeMany(parameters.map(\.changes)).sink { [weak self] in
            guard let self, !self.updating else { return }
            self.changed.send()
        }
    }

    public var settings: EQSettings {
        EQSettings(gains: bands.map { $0.gain.value }, frequencies: bands.map { $0.frequency.value },
            bandwidths: bands.map { $0.bandwidth.value }, gainDB: gain.value, enabled: enabled)
    }

    public func updateSettings(_ settings: EQSettings) {
        precondition(settings.gains.count == bands.count && settings.frequencies.count == bands.count
            && settings.bandwidths.count == bands.count)
        let previous = self.settings
        updating = true
        gain.setValue(settings.gainDB)
        for index in bands.indices {
            bands[index].gain.setValue(settings.gains[index])
            bands[index].frequency.setValue(settings.frequencies[index])
            bands[index].bandwidth.setValue(settings.bandwidths[index])
        }
        enabled = settings.enabled
        updating = false
        if self.settings != previous { changed.send() }
    }
}
