import MixerCore

public enum PresetError: Error { case requiredNodeRemoved(String) }

@MainActor
public final class ConsoleChannel: Channel {
    public let equalizer: Equalizer
    public let panStage: PanNode
    public let widthStage: WidthNode
    public let volumeStage: VolumeNode
    public var volume: Parameter { volumeStage.volume }
    public var width: Parameter { widthStage.width }
    public override var configurationVersion: Int { 2 }
    public var pan: Parameter { panStage.pan }

    public init(id: String, settings: ChannelSettings = ChannelSettings()) {
        equalizer = Equalizer(id: id + ".eq", settings: settings.eqSettings)
        widthStage = WidthNode(id: id + ".width", value: settings.width)
        panStage = PanNode(id: id + ".pan", value: settings.pan)
        volumeStage = VolumeNode(id: id + ".volume", value: settings.volume)
        super.init(id: id, typeID: "standard.console-channel", nodes: [equalizer, widthStage, panStage, volumeStage],
            isMuted: settings.isMuted, isSolo: settings.isSolo)
    }

    public override func validateProcessingNodes(_ nodes: [MixerNode]) throws {
        for required in [equalizer, widthStage, panStage, volumeStage] as [MixerNode] {
            guard nodes.contains(where: { $0 === required }) else { throw PresetError.requiredNodeRemoved(required.id) }
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
        settings.width = width.value
        settings.isMuted = isMuted
        settings.isSolo = isSolo
        return settings
    }

    public func updateSettings(_ settings: ChannelSettings) {
        performUpdate {
            equalizer.updateSettings(settings.eqSettings)
            volume.setValue(settings.volume)
            pan.setValue(settings.pan)
            width.setValue(settings.width)
            setMuted(settings.isMuted)
            setSolo(settings.isSolo)
        }
    }
}
