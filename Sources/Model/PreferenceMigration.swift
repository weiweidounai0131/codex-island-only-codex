import Foundation

enum PreferenceMigration {
    private static let oldBundleID = "dev.codexisland.CodexIsland"
    private static let markerKey = "PreferenceMigration.didImportFromCodexIsland"

    static func importLegacyPreferencesIfNeeded() {
        guard let newBundleID = Bundle.main.bundleIdentifier,
              newBundleID != oldBundleID else { return }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: markerKey) == false else { return }

        defer {
            defaults.set(true, forKey: markerKey)
            defaults.synchronize()
        }

        guard let legacy = defaults.persistentDomain(forName: oldBundleID),
              legacy.isEmpty == false else { return }

        let current = defaults.dictionaryRepresentation()
        for (key, value) in legacy where current[key] == nil {
            defaults.set(value, forKey: key)
        }
    }
}
