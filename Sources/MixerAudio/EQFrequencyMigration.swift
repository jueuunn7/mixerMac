import Foundation
import MixerStandardNodes

public extension ConsolePreferences {
    /// Normalize existing console EQs once, retaining later Detail edits and
    /// every setting other than the ten band centre frequencies.
    static func standardizeEQFrequencies(defaults: UserDefaults = .standard) {
        let marker = "settings.standardEQFrequencies.v1"
        guard !defaults.bool(forKey: marker) else { return }
        var originals = defaults.dictionary(forKey: "backup.beforeStandardEQFrequencies") ?? [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key == "mixer.graph.v1" || key == "master.eq" || key.hasPrefix("channel."),
                  let data = value as? Data,
                  var document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let original = document
            if key == "mixer.graph.v1" {
                guard let nodes = document["nodes"] as? [[String: Any]] else { continue }
                document["nodes"] = nodes.map(standardizedNode)
            } else if key.hasPrefix("channel.nodes.") {
                document = standardizedNode(document)
            } else {
                // Legacy channel/master settings remain valid fallbacks for
                // the graph-backed runtime and must use the same frequencies.
                document[key == "master.eq" ? "bandFrequencies" : "frequencies"] = EQSettings.frequencies
            }
            guard let updated = try? JSONSerialization.data(withJSONObject: document),
                  !NSDictionary(dictionary: document).isEqual(NSDictionary(dictionary: original)) else { continue }
            if originals[key] == nil { originals[key] = data }
            defaults.set(originals, forKey: "backup.beforeStandardEQFrequencies")
            defaults.set(updated, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }

    private static func standardizedNode(_ node: [String: Any]) -> [String: Any] {
        var result = node
        if node["typeID"] as? String == StandardNodeType.parametricEQ,
           var parameters = node["parameters"] as? [String: Any] {
            for (index, frequency) in EQSettings.frequencies.enumerated() {
                let key = "band.\(index).frequency"
                if parameters[key] != nil { parameters[key] = frequency }
            }
            result["parameters"] = parameters
        }
        if let children = node["children"] as? [[String: Any]] {
            result["children"] = children.map(standardizedNode)
        }
        return result
    }
}
