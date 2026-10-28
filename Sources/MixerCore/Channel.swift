import Combine

@MainActor
public final class Channel: Identifiable {
    public let id: String
    public let equalizer: Equalizer
    public let volume: Parameter
    public let pan: Parameter
    public private(set) var isMuted: Bool
    public private(set) var isSolo: Bool
    private let changed = PassthroughSubject<Void, Never>()
    public var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    private var subscription: AnyCancellable?
    private var updating = false

    public init(id: String, settings: ChannelSettings = ChannelSettings()) {
        self.id = id
        equalizer = Equalizer(settings: settings.eqSettings)
        volume = Parameter(value: settings.volume, range: 0...1, defaultValue: 1, unit: .linearGain)
        pan = Parameter(value: settings.pan, range: -1...1, defaultValue: 0, unit: .balance)
        isMuted = settings.isMuted
        isSolo = settings.isSolo
        subscription = Publishers.MergeMany([equalizer.changes, volume.changes, pan.changes]).sink { [weak self] in
            guard let self, !self.updating else { return }
            self.changed.send()
        }
    }

    public var settings: ChannelSettings {
        let eq = equalizer.settings
        var settings = ChannelSettings()
        settings.gains = eq.gains
        settings.frequencies = eq.frequencies
        settings.bandwidths = eq.bandwidths
        settings.trimDB = eq.gainDB
        settings.eqEnabled = eq.enabled
        settings.volume = volume.value
        settings.pan = pan.value
        settings.isMuted = isMuted
        settings.isSolo = isSolo
        return settings
    }

    public func updateSettings(_ settings: ChannelSettings) {
        let previous = self.settings
        updating = true
        equalizer.updateSettings(settings.eqSettings)
        volume.setValue(settings.volume)
        pan.setValue(settings.pan)
        isMuted = settings.isMuted
        isSolo = settings.isSolo
        updating = false
        if self.settings != previous { changed.send() }
    }

    public func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        changed.send()
    }

    public func setSolo(_ solo: Bool) {
        guard isSolo != solo else { return }
        isSolo = solo
        changed.send()
    }
}
