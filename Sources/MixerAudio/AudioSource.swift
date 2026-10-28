import MixerCore
@preconcurrency import AVFAudio

@MainActor
open class AudioSource {
    public enum State: Equatable { case stopped, prepared, running, failed }
    public let model: MixerNode
    public final private(set) var state: State = .stopped
    public final private(set) var endpoint: AudioEndpoint?
    private var ownsResources = false

    public init(model: MixerNode) { self.model = model }

    public final func prepare() throws -> AudioEndpoint {
        stop()
        ownsResources = true
        do {
            let endpoint = try prepareResources()
            self.endpoint = endpoint
            state = .prepared
            return endpoint
        } catch { stop(); state = .failed; throw error }
    }

    public final func activate() throws {
        guard state == .prepared else { throw AudioSourceError.invalidState }
        do { try activateResources(); state = .running }
        catch { stop(); state = .failed; throw error }
    }

    public final func synchronize() throws {
        guard state == .running else { return }
        try updateResources()
    }

    public final func stop() {
        if ownsResources { releaseResources() }
        ownsResources = false
        endpoint = nil
        state = .stopped
    }

    open func prepareResources() throws -> AudioEndpoint { throw AudioSourceError.unimplemented }
    open func activateResources() throws {}
    open func updateResources() throws {}
    open func releaseResources() {}
}

public enum AudioSourceError: Error, Equatable {
    case invalidState
    case unimplemented
    case duplicateRegistration(String)
    case unregisteredType(String)
    case incompatibleSource(String)
}

@MainActor
public final class AudioSourceRegistry {
    private var factories: [String: @MainActor (MixerNode) throws -> AudioSource] = [:]
    public init() {}

    public func register<Node: MixerNode>(_ typeID: String, nodeType: Node.Type,
                                         factory: @escaping @MainActor (Node) throws -> AudioSource) throws {
        guard factories[typeID] == nil else { throw AudioSourceError.duplicateRegistration(typeID) }
        factories[typeID] = { node in
            guard let typed = node as? Node else { throw AudioSourceError.incompatibleSource(node.id) }
            return try factory(typed)
        }
    }

    public func make(_ model: MixerNode) throws -> AudioSource {
        guard let factory = factories[model.typeID] else { throw AudioSourceError.unregisteredType(model.typeID) }
        let source = try factory(model)
        guard source.model === model else { throw AudioSourceError.incompatibleSource(model.id) }
        return source
    }
}
