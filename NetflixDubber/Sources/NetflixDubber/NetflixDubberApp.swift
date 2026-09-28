import AppKit
import SwiftUI

@main
struct NetflixDubberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var controller: DubbingController

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: DubbingController(settings: settings))
    }

    var body: some Scene {
        WindowGroup("Netflix Dubber") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(controller)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also makes `swift run` (no .app bundle) show a normal window and Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the Mac's audio muted by a lingering tap.
        MainActor.assumeIsolated {
            DubbingController.active?.emergencyStop()
        }
    }
}
