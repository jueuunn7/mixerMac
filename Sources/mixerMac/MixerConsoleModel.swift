import AppKit
import MixerAudio

@MainActor
final class MixerConsoleModel: MixerSession {
    func tick() {
        let visible = NSApp.isActive || NSApp.windows.contains {
            $0.occlusionState.contains(.visible) && !$0.isMiniaturized
        }
        tick(updateMeters: visible)
    }
}
