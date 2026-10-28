import Combine

public enum MixerChange: Equatable, Sendable {
    case channels
    case channel(String)
    case master
}

@MainActor
public final class Mixer {
    public private(set) var channels: [Channel] = []
    public let master: MixBus
    private let changed = PassthroughSubject<MixerChange, Never>()
    public var changes: AnyPublisher<MixerChange, Never> { changed.eraseToAnyPublisher() }
    private var channelSubscriptions: [AnyCancellable] = []
    private var masterSubscription: AnyCancellable?

    public init(channels: [Channel] = [], masterSettings: BusEQSettings = BusEQSettings()) {
        master = MixBus(settings: masterSettings)
        masterSubscription = master.changes.sink { [weak self] in self?.changed.send(.master) }
        replaceChannels(channels)
    }

    public func addChannel(_ channel: Channel) { replaceChannels(channels + [channel]) }

    public func removeChannel(id: String) { replaceChannels(channels.filter { $0.id != id }) }

    public func replaceChannels(_ channels: [Channel]) {
        precondition(Set(channels.map(\.id)).count == channels.count, "Channel IDs must be unique")
        if self.channels.count == channels.count && zip(self.channels, channels).allSatisfy({ $0 === $1 }) { return }
        channelSubscriptions.removeAll()
        self.channels = channels
        channelSubscriptions = channels.map { channel in
            channel.changes.sink { [weak self, id = channel.id] in self?.changed.send(.channel(id)) }
        }
        changed.send(.channels)
    }

    public var audibleChannelIDs: Set<String> {
        let anySolo = channels.contains { $0.isSolo }
        return Set(channels.filter { !$0.isMuted && (!anySolo || $0.isSolo) }.map(\.id))
    }
}
