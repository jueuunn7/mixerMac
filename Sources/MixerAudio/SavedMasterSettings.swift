import Foundation
import MixerCore
import MixerStandardNodes

extension BusEQSettings {
    static func restored(defaults: UserDefaults = .standard) -> BusEQSettings {
        guard let data = defaults.data(forKey: "master.eq"),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        saved.enabled = true
        return saved
    }

}
