import SwiftUI
import AppKit

@main
struct CodexIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        // Placeholder scene — `App` requires at least one `Scene`. We never
        // trigger the system Settings menu (we're a `.accessory` app with
        // no menu bar), so this stays inert. Settings is shown via our own
        // SettingsWindowController.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var island: IslandWindowController?
    private var settingsShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferenceMigration.importLegacyPreferencesIfNeeded()

        NSApp.setActivationPolicy(.accessory)
        island = IslandWindowController()
        island?.show()
        closeRestoredPlaceholderWindows()

        // Route Cmd+, to our hand-rolled Settings window. Without this, the
        // inert `Settings { EmptyView() }` scene below claims the shortcut and
        // opens a blank window. Consuming the event (returning nil) keeps that
        // empty scene from ever surfacing.
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

    /// SwiftUI's `App` lifecycle requires at least one `Scene`, so we keep an
    /// inert `Settings { EmptyView() }` placeholder above and open our real
    /// settings via `SettingsWindowController`. macOS can still restore that
    /// placeholder across launches before our delegate runs; close only those
    /// empty SwiftUI windows, leaving the island and the real settings window
    /// alone.
    private func closeRestoredPlaceholderWindows() {
        DispatchQueue.main.async {
            for window in NSApp.windows where Self.isRestoredPlaceholder(window) {
                window.close()
            }
        }
    }

    private static func isRestoredPlaceholder(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        if window is BorderlessFloatingWindow { return false }
        guard let controller = window.contentViewController else { return false }
        let controllerName = String(describing: type(of: controller))
        return controllerName.contains("NSHostingController")
            && window.title.isEmpty
            && window.contentView?.subviews.isEmpty == false
    }
}
