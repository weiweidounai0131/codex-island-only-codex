import Foundation

/// Raw per-turn token usage kept separate from the cost pipeline.
/// `inputTokens` intentionally includes cached input, matching Codex's
/// `last_token_usage` payload and the CH definition in the PRD.
struct CodexCacheHitSnapshot: Equatable, Identifiable {
    let sessionID: String
    let turnID: String
    let timestamp: Date
    let model: String?
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    let modelContextWindow: Int?
    let lastTotalTokens: Int?
    let lastInputTokens: Int?
    let lastCachedInputTokens: Int?

    init(
        sessionID: String,
        turnID: String,
        timestamp: Date,
        model: String?,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        modelContextWindow: Int?,
        cacheWriteInputTokens: Int = 0,
        lastTotalTokens: Int? = nil,
        lastInputTokens: Int? = nil,
        lastCachedInputTokens: Int? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.modelContextWindow = modelContextWindow
        self.lastTotalTokens = lastTotalTokens
        self.lastInputTokens = lastInputTokens
        self.lastCachedInputTokens = lastCachedInputTokens
    }

    var id: String { "\(sessionID):\(turnID)" }

    /// Same names as CodexHost's renderer usage contract.
    var contextUsedTokens: Int? { lastTotalTokens }
    var contextWindowTokens: Int? { modelContextWindow }

    var cacheHitRatePercent: Double? {
        // CodexHost calculates CH from the latest request only. Never fall
        // back to cumulative totals because that produces a different metric.
        guard let input = lastInputTokens,
              let cached = lastCachedInputTokens else {
            return nil
        }
        guard input > 0 else { return nil }
        let raw = Double(cached) / Double(input) * 100
        return min(100, max(0, raw))
    }

    var hasUsage: Bool {
        inputTokens > 0
            || cachedInputTokens > 0
            || cacheWriteInputTokens > 0
            || outputTokens > 0
            || reasoningOutputTokens > 0
            || totalTokens > 0
    }
}
