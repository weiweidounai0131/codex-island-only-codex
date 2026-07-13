import Foundation

/// One rate-limit window (e.g. Claude's 5h, Codex's 7d). usedPercent is
/// normalized to 0...1 regardless of what the upstream API returns.
struct WindowUsage {
    let usedPercent: Double
    let resetAt: Date?
    let error: String?
    let windowSeconds: Int?

    static let unknown = WindowUsage(usedPercent: 0, resetAt: nil, error: "no data")
    static let unavailable = WindowUsage(usedPercent: 0, resetAt: nil, error: "unavailable")

    init(usedPercent: Double, resetAt: Date?, error: String?, windowSeconds: Int? = nil) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.error = error
        self.windowSeconds = windowSeconds
    }

    var percentInt: Int { Int((usedPercent * 100).rounded()) }

    var isUnavailable: Bool { error == "unavailable" }

    func displayedFraction(mode: UsageDisplayMode) -> Double {
        switch mode {
        case .used:
            return usedPercent
        case .remaining:
            return max(0, 1 - usedPercent)
        }
    }

    func displayedPercentInt(mode: UsageDisplayMode) -> Int {
        Int((displayedFraction(mode: mode) * 100).rounded())
    }

    func displayLabel(defaultKey: String) -> String {
        guard let seconds = windowSeconds, seconds > 0 else {
            return defaultKey
        }
        if seconds >= 604_800 {
            return "week"
        }
        if seconds >= 86_400 {
            return "\(Int((Double(seconds) / 86_400).rounded()))d"
        }
        if seconds >= 3_600 {
            return "\(Int((Double(seconds) / 3_600).rounded()))h"
        }
        return defaultKey
    }

    var compactWindowLengthText: String? {
        guard let seconds = windowSeconds, seconds > 0 else { return nil }
        if seconds >= 604_800 { return "7d" }
        if seconds >= 86_400 { return "\(Int((Double(seconds) / 86_400).rounded()))d" }
        if seconds >= 3_600 { return "\(Int((Double(seconds) / 3_600).rounded()))h" }
        return nil
    }
}

struct AppUsage {
    var fiveHour: WindowUsage
    var weekly: WindowUsage
    /// Provider-reported plan tier — Claude's `subscriptionType` (free/pro/max)
    /// or Codex's `plan_type` (free/plus/pro). nil when unknown.
    var plan: String?

    init(fiveHour: WindowUsage, weekly: WindowUsage, plan: String? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.plan = plan
    }

    static let empty = AppUsage(fiveHour: .unknown, weekly: .unknown)

    /// Placeholder values shown when a provider is toggled off. Non-zero
    /// so the chart vocabulary stays visible (a 0% ring reads as broken,
    /// a 45% ring reads as "data we're choosing not to surface").
    static let dummy = AppUsage(
        fiveHour: WindowUsage(usedPercent: 0.45, resetAt: nil, error: nil),
        weekly: WindowUsage(usedPercent: 0.28, resetAt: nil, error: nil)
    )
}
