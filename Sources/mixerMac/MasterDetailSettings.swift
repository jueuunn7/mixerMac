import MixerCore

extension BusEQSettings {
    var detailSettings: ChannelSettings {
        get {
            var settings = ChannelSettings()
            settings.gains = gains
            settings.frequencies = bandFrequencies
            settings.bandwidths = bandwidths
            settings.trimDB = eqSettings.gainDB
            settings.pan = pan
            settings.eqEnabled = enabled
            return settings
        }
        set {
            gains = newValue.gains.map { $0.isFinite ? min(24, max(-24, $0)) : 0 }
            bandFrequencies = newValue.frequencies
            bandwidths = newValue.bandwidths
            gainDB = (newValue.trimDB.isFinite ? min(24, max(-24, newValue.trimDB)) : 0)
            pan = PanBalance.clamped(newValue.pan)
            enabled = true
        }
    }

}
