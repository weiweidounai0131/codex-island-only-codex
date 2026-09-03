import Combine
import Foundation

/// Independent opt-in for the PRD's conversation-usage enhancement.
/// Existing quota/cost preferences intentionally do not control this switch.
@MainActor
final class CodexConversationUsagePreference: ObservableObject {
    static let shared = CodexConversationUsagePreference()

    private static let key = "CodexIsland.conversationUsageEnabled"
    private static let defaultEnabled = false

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool
            ?? Self.defaultEnabled
    }
}
