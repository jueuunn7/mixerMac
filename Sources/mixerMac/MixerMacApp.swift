import SwiftUI
import AppKit

@main
struct MixerMacApp: App {
    @NSApplicationDelegateAdaptor(MixerMacAppDelegate.self) private var appDelegate
    init() { ConsolePreferences.migrateLegacySettings() }

    var body: some Scene {
        Window("mixerMac", id: "main") {
            MixerConsoleView()
                .frame(minWidth: ConsoleLayout.minimumWindowWidth, minHeight: ConsoleLayout.windowHeight)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: ConsoleLayout.windowWidth, height: ConsoleLayout.windowHeight)
    }
}

@MainActor
final class MixerMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        // Apply the console's current opening size even when macOS restores
        // a window frame saved by an earlier layout.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == "mixerMac" }) else { return }
            window.setContentSize(NSSize(width: ConsoleLayout.windowWidth,
                                         height: ConsoleLayout.windowHeight))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
