@MainActor
open class Channel: ProcessingChain {
    public let mute: Parameter
    public let solo: Parameter
    public final var isMuted: Bool { mute.value == 1 }
    public final var isSolo: Bool { solo.value == 1 }

    public init(id: String, typeID: String = "core.channel", nodes: [MixerNode] = [],
                isMuted: Bool = false, isSolo: Bool = false) {
        mute = Parameter(value: isMuted ? 1 : 0, range: 0...1, defaultValue: 0, unit: .boolean, step: 1)
        solo = Parameter(value: isSolo ? 1 : 0, range: 0...1, defaultValue: 0, unit: .boolean, step: 1)
        super.init(id: id, typeID: typeID, nodes: nodes, parameters: ["mute": mute, "solo": solo])
    }

    public static func audibleIDs(in channels: [Channel], activeIDs: Set<String>? = nil) -> Set<String> {
        let active = channels.filter { activeIDs?.contains($0.id) ?? true }
        let anySolo = active.contains { $0.isSolo }
        return Set(active.filter { !$0.isMuted && (!anySolo || $0.isSolo) }.map(\.id))
    }

    public final func setMuted(_ muted: Bool) { mute.setValue(muted ? 1 : 0) }
    public final func setSolo(_ solo: Bool) { self.solo.setValue(solo ? 1 : 0) }
}
