import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    var island: IslandWindowController?
    private var settingsShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferenceMigration.importLegacyPreferencesIfNeeded()

        NSApp.setActivationPolicy(.accessory)
        island = IslandWindowController()
        island?.show()

        // Route Cmd+, to our hand-rolled Settings window. The app now uses a
        // pure AppKit lifecycle, so there is no SwiftUI Settings scene for
        // macOS to restore as an empty placeholder window.
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "," {
                SettingsWindowController.shared.show()
                return nil
            }
            return event
        }

        // Start fetching at app launch — NOT on view appear — so the panel
        // already has cached values the first time the user hovers, instead
        // of flashing "0%" while the first request lands.
        UsageStore.shared.startAutoRefresh()
        CostStore.shared.startAutoRefresh()

        // Wire the alert engine after the usage store so its initial
        // recompute sees whatever values the first refresh has produced.
        AlertEngine.shared.start()

    }

    /// Pin the app to the run loop until the user explicitly quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }
}
