import MixerCore

@MainActor
public final class ConsoleBus: MixBus {
    public let equalizer: Equalizer
    public let panStage: PanNode
    public let widthStage: WidthNode
    public var pan: Parameter { panStage.pan }
    public var width: Parameter { widthStage.width }

    public init(id: String = "master", settings: BusEQSettings = BusEQSettings()) {
        equalizer = Equalizer(id: id + ".eq", settings: settings.eqSettings)
        equalizer.setBypassed(!settings.enabled)
        panStage = PanNode(id: id + ".pan", value: settings.pan)
        widthStage = WidthNode(id: id + ".width", value: settings.width)
        super.init(id: id, typeID: "standard.console-bus", nodes: [equalizer, widthStage, panStage])
    }

    public override func validateProcessingNodes(_ nodes: [MixerNode]) throws {
        for required in [equalizer, widthStage, panStage] as [MixerNode] {
            guard nodes.contains(where: { $0 === required }) else { throw PresetError.requiredNodeRemoved(required.id) }
        }
    }

    public var settings: BusEQSettings {
        let eq = equalizer.settings
        var settings = BusEQSettings()
        settings.gains = eq.gains
        settings.bandFrequencies = eq.frequencies
        settings.bandwidths = eq.bandwidths
        settings.gainDB = eq.gainDB
        settings.enabled = !equalizer.isBypassed && eq.enabled
        settings.pan = pan.value
        settings.width = width.value
        return settings
    }

    public func resetTone() {
        updateSettings(BusEQSettings())
    }

    public func updateSettings(_ settings: BusEQSettings) {
        performUpdate {
            equalizer.updateSettings(settings.eqSettings)
            equalizer.setBypassed(!settings.enabled)
            pan.setValue(settings.pan)
            width.setValue(settings.width)
        }
    }
}

public typealias ConsoleMixer = Mixer<ConsoleBus>

public extension Mixer where Master == ConsoleBus {
    convenience init(channels: [Channel] = [], masterSettings: BusEQSettings = BusEQSettings()) {
        self.init(master: ConsoleBus(settings: masterSettings), channels: channels)
    }
}
