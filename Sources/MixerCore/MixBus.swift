import Combine

@MainActor
public final class MixBus {
    public let equalizer: Equalizer
    public let pan: Parameter
    public let width: Parameter
    private let changed = PassthroughSubject<Void, Never>()
    public var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    private var subscription: AnyCancellable?
    private var updating = false

    public init(settings: BusEQSettings = BusEQSettings()) {
        equalizer = Equalizer(settings: settings.eqSettings)
        pan = Parameter(value: settings.pan, range: -1...1, defaultValue: 0, unit: .balance)
        width = Parameter(value: settings.width, range: 0...2, defaultValue: 1, unit: .ratio)
        subscription = Publishers.MergeMany([equalizer.changes, pan.changes, width.changes]).sink { [weak self] in
            guard let self, !self.updating else { return }
            self.changed.send()
        }
    }

    public var settings: BusEQSettings {
        let eq = equalizer.settings
        var settings = BusEQSettings()
        settings.gains = eq.gains
        settings.bandFrequencies = eq.frequencies
        settings.bandwidths = eq.bandwidths
        settings.gainDB = eq.gainDB
        settings.enabled = eq.enabled
        settings.pan = pan.value
        settings.width = width.value
        return settings
    }

    public func updateSettings(_ settings: BusEQSettings) {
        let previous = self.settings
        updating = true
        equalizer.updateSettings(settings.eqSettings)
        pan.setValue(settings.pan)
        width.setValue(settings.width)
        updating = false
        if self.settings != previous { changed.send() }
    }
}
