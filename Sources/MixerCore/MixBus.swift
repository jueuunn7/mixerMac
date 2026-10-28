@MainActor
open class MixBus: ProcessingChain {
    public init(id: String, typeID: String = "core.bus", nodes: [MixerNode] = []) {
        super.init(id: id, typeID: typeID, nodes: nodes)
    }
}
