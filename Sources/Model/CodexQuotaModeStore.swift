import Foundation

enum CodexQuotaMode: String, CaseIterable {
    case weekly
    case hourlyAndWeekly

    var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .hourlyAndWeekly: return "Hourly"
        }
    }
}

@MainActor
final class CodexQuotaModeStore: ObservableObject {
    static let shared = CodexQuotaModeStore()

    private static let key = "MacIsland.codexQuotaMode"

    @Published var mode: CodexQuotaMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    private init() {
        self.mode = Pref.enumValue(key: Self.key, default: .weekly)
    }
}
