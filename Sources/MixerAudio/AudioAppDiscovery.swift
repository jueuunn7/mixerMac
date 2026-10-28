import AppKit
import CoreAudio

public struct AudioApp: Identifiable {
    public let id: String
    public let name: String
    public let icon: NSImage?
    public var processes: [AudioObjectID]
    public var isPlaying: Bool
}

@MainActor
public enum AudioAppDiscovery {
    public static func processIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &ids) == noErr else { return [] }
        return ids
    }

    public static func number(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    public static func ownProcesses() -> [AudioObjectID] {
        processIDs().filter { number($0, selector: kAudioProcessPropertyPID) == UInt32(ProcessInfo.processInfo.processIdentifier) }
    }

    public static func apps() -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var groups: [String: AudioApp] = [:]
        for object in processIDs() {
            let pid = pid_t(number(object, selector: kAudioProcessPropertyPID))
            guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let direct = NSRunningApplication(processIdentifier: pid)
            let bundle = AudioDevices.string(object, selector: kAudioProcessPropertyBundleID) ?? direct?.bundleIdentifier ?? ""
            // A system-wide routing host already contains other apps' mix.
            // Tapping it alongside those apps can duplicate the same audio.
            guard !bundle.hasPrefix("local.mixermac"), !bundle.hasPrefix("com.bitgapp.eqmac") else { continue }
            let app = running.first(where: { $0.processIdentifier == pid })
                ?? running.first(where: { candidate in
                    guard let id = candidate.bundleIdentifier else { return false }
                    return bundle == id || bundle.hasPrefix(id + ".")
                })
                ?? running.first(where: { candidate in
                    guard let root = candidate.bundleURL?.path, let path = direct?.bundleURL?.path else { return false }
                    return path.hasPrefix(root + "/")
                })
            guard let app, let id = app.bundleIdentifier,
                  !id.hasPrefix("local.mixermac"), !id.hasPrefix("com.bitgapp.eqmac") else { continue }
            let playing = number(object, selector: kAudioProcessPropertyIsRunningOutput) != 0
            if var group = groups[id] {
                group.processes.append(object)
                group.isPlaying = group.isPlaying || playing
                groups[id] = group
            } else {
                groups[id] = AudioApp(id: id, name: app.localizedName ?? bundle, icon: app.icon,
                                      processes: [object], isPlaying: playing)
            }
        }
        return groups.values.map { value in
            var value = value
            value.processes.sort()
            return value
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
