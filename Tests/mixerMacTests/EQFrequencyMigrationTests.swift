import Foundation
import MixerAudio
import MixerCore
import MixerStandardNodes
import Testing

struct EQFrequencyMigrationTests {
    @Test @MainActor func savedGraphAndLegacySettingsUseSharedFrequenciesWithoutLosingControls() throws {
        let domain = "mixerMac.FrequencyMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var settings = ChannelSettings()
        settings.frequencies[0] = 66
        settings.frequencies[8] = 20_000
        settings.gains[8] = 3.5
        settings.bandwidths[2] = 1.7
        settings.pan = -0.3
        settings.volume = 0.6
        settings.isMuted = true
        let channel = ConsoleChannel(id: "music", settings: settings)
        let mixer = ConsoleMixer(channels: [channel])
        mixer.master.equalizer.bands[1].frequency.setValue(90)
        mixer.master.equalizer.bands[1].gain.setValue(-2)
        mixer.master.width.setValue(1.4)
        let encoder = JSONEncoder()
        let saved: [String: Data] = [
            "mixer.graph.v1": try encoder.encode(GraphSnapshot(mixer.graph)),
            "channel.nodes.music": try encoder.encode(NodeSnapshot(channel)),
            "channel.music": try encoder.encode(settings),
            "master.eq": try encoder.encode(mixer.master.settings)
        ]
        for (key, data) in saved { defaults.set(data, forKey: key) }
        ConsolePreferences.standardizeEQFrequencies(defaults: defaults)

        let registry = try StandardNodeRegistry.make()
        let graph = AudioGraph()
        try registry.restore(JSONDecoder().decode(GraphSnapshot.self,
            from: #require(defaults.data(forKey: "mixer.graph.v1"))), into: graph)
        let restored = try #require(graph.nodes.first { $0.id == "music" } as? ConsoleChannel)
        settings.frequencies = EQSettings.frequencies
        #expect(restored.settings == settings)
        let master = try #require(graph.nodes.first { $0.id == "master" } as? ConsoleBus)
        #expect(master.settings.bandFrequencies == EQSettings.frequencies)
        #expect(master.settings.gains[1] == -2)
        #expect(master.settings.width == 1.4)
        let legacy = try JSONDecoder().decode(ChannelSettings.self,
            from: #require(defaults.data(forKey: "channel.music")))
        #expect(legacy == settings)
        let node = try registry.makeNode(from: JSONDecoder().decode(NodeSnapshot.self,
            from: #require(defaults.data(forKey: "channel.nodes.music"))))
        #expect((node as? ConsoleChannel)?.settings == settings)
        let legacyMaster = try JSONDecoder().decode(BusEQSettings.self,
            from: #require(defaults.data(forKey: "master.eq")))
        #expect(legacyMaster == master.settings)
        let backup = try #require(defaults.dictionary(forKey: "backup.beforeStandardEQFrequencies"))
        for (key, data) in saved { #expect(backup[key] as? Data == data) }

        // A subsequent user edit in Detail must survive future app launches.
        settings.frequencies[0] = 45
        defaults.set(try encoder.encode(settings), forKey: "channel.music")
        ConsolePreferences.standardizeEQFrequencies(defaults: defaults)
        let edited = try JSONDecoder().decode(ChannelSettings.self,
            from: #require(defaults.data(forKey: "channel.music")))
        #expect(edited.frequencies[0] == 45)
    }
}
