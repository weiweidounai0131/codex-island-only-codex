import Foundation

/// Provider visibility is now fixed to Codex. The type stays in place so
/// older provider-keyed views can ask the same question while the UI moves
/// as a single-service app.
@MainActor
final class ProviderVisibilityStore: ObservableObject {
    static let shared = ProviderVisibilityStore()

    @Published private(set) var claudeVisible = false
    @Published private(set) var codexVisible = true

    private init() {}

    /// Single accessor for call sites that have an `AlertEngine.Provider`
    /// in hand. Equivalent to reading `claudeVisible` / `codexVisible`
    /// directly; centralizes the lookup so the few provider-keyed call
    /// sites read uniformly.
    func effectiveVisible(provider: AlertEngine.Provider) -> Bool {
        switch provider {
        case .claude: return false
        case .codex:  return true
        }
    }
}
