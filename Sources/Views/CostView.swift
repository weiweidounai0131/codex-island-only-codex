import SwiftUI

/// Codex cost row. Mirrors `UsageView`'s single-provider layout so page
/// transitions no longer reflow around an absent Claude column.
struct CostView: View {
    @ObservedObject private var store = CostStore.shared
    @ObservedObject private var stylePref = CostStylePref.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                CompactCostTile(
                    color: IslandColor.codex,
                    window: store.codex.today,
                    loading: store.codexLoading,
                    isMonth: false
                )
                CompactCostTile(
                    color: IslandColor.codex,
                    window: store.codex.month,
                    loading: store.codexLoading,
                    isMonth: true
                )
            }
            .frame(width: 210, alignment: .topLeading)

            hairline

            PerModelBreakdown(provider: .codex, metric: breakdownMetric)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var breakdownMetric: PerModelBreakdown.Metric {
        stylePref.style == .tokens ? .tokens : .dollars
    }

    private var hairline: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, .white.opacity(0.06), .clear],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 1, height: 94)
    }
}

private struct CompactCostTile: View {
    let color: Color
    let window: CostWindow
    let loading: Bool
    let isMonth: Bool

    @ObservedObject private var stylePref = CostStylePref.shared
    @ObservedObject private var tokenMode = TokenCountModeStore.shared
    @ObservedObject private var usageStore = UsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr(window.label))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 8)
                Text(resetGlyph)
                    .font(Typography.caption)
                    .foregroundStyle(.white.opacity(window.unknownModels.isEmpty ? 0.40 : 0.55))
                    .lineLimit(1)
                    .help(resetGlyphSpoken)
                    .accessibilityLabel(resetGlyphSpoken)
            }

            valueLine
        }
        .frame(height: 43, alignment: .topLeading)
        .opacity(loading ? 0.7 : 1.0)
        .animation(.easeOut(duration: 0.18), value: loading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(window.label)
        .accessibilityValue(spokenValue)
    }

    @ViewBuilder
    private var valueLine: some View {
        switch stylePref.style {
        case .tokens:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(tokensValue)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(glowOpacity), radius: 5)
                Text(tokensUnit)
                    .font(Typography.unit)
                    .foregroundStyle(.white.opacity(0.4))
            }
        case .multi:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(valueMultiplier)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(glowOpacity), radius: 5)
                    .shadow(color: color.opacity(glowOpacity * 0.45), radius: 12)
                Text("×")
                    .font(Typography.unit)
                    .foregroundStyle(.white.opacity(0.4))
                if let planLabel {
                    Text(planLabel)
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.36))
                        .padding(.leading, 2)
                }
            }
        case .spark:
            ZStack(alignment: .bottomTrailing) {
                CostSparkline(series: window.series, color: color)
                    .frame(width: 178, height: 24)
                    .opacity(0.9)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("$")
                        .font(Typography.micro)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(formattedDollarsCompact)
                        .font(Typography.bodyNumber)
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(0.65), radius: 3)
                }
            }
        case .dollar:
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("$")
                    .font(Typography.unit)
                    .foregroundStyle(.white.opacity(0.4))
                Text(formattedDollarsCompact)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(glowOpacity), radius: 5)
                    .shadow(color: color.opacity(glowOpacity * 0.45), radius: 12)
            }
        }
    }

    private var spokenValue: String {
        switch stylePref.style {
        case .tokens:
            return L10n.tr("%@%@ tokens", tokensValue, tokensUnit)
        case .multi:
            guard let planLabel else { return L10n.tr("$%@", formattedDollarsCompact) }
            return L10n.tr("%@ times %@ plan value", valueMultiplier, planLabel)
        case .spark:
            return L10n.tr("$%@ trend", formattedDollarsCompact)
        case .dollar:
            return "$\(formattedDollarsCompact)"
        }
    }

    private var displayedTokens: Int {
        switch tokenMode.mode {
        case .all:      return window.tokens
        case .billable: return window.billableTokens
        }
    }

    private var tokensValue: String {
        let n = displayedTokens
        let v = Double(n)
        if n < 1_000 { return "\(n)" }
        if n < 10_000 { return String(format: "%.1f", v / 1_000) }
        if n < 1_000_000 { return String(format: "%.0f", v / 1_000) }
        if n < 1_000_000_000 { return String(format: "%.1f", v / 1_000_000) }
        return String(format: "%.1f", v / 1_000_000_000)
    }

    private var tokensUnit: String {
        let n = displayedTokens
        if n < 1_000 { return "tok" }
        if n < 1_000_000 { return "k" }
        if n < 1_000_000_000 { return "M" }
        return "B"
    }

    private var formattedDollarsCompact: String {
        let v = window.dollars
        if v < 100 { return String(format: "%.2f", v) }
        return String(format: "%.0f", v)
    }

    private var valueMultiplier: String {
        let plan = planAmount
        guard plan > 0 else { return "—" }
        let ratio = window.dollars / plan
        if ratio < 10 { return String(format: "%.1f", ratio) }
        return String(format: "%.0f", ratio)
    }

    private var planAmount: Double {
        switch usageStore.codex.plan?.lowercased() {
        case "plus": return 20
        case "pro":  return 200
        default:     return 0
        }
    }

    private var planLabel: String? {
        switch usageStore.codex.plan?.lowercased() {
        case "plus": return "Plus"
        case "pro":  return "Pro"
        default:     return nil
        }
    }

    private var glowOpacity: Double {
        let s = window.dollars
        if s <= 0 { return 0 }
        let scale = log(s + 1) / log(2000)
        return min(0.85, 0.20 + scale * 0.65)
    }

    private var resetGlyph: String {
        if let err = window.error { return err }
        if !window.unknownModels.isEmpty {
            return L10n.tr("⚠ %d", window.unknownModels.count)
        }
        return "↻ " + (isMonth ? CostBucketing.monthResetIn() : CostBucketing.todayResetIn())
    }

    private var resetGlyphSpoken: String {
        if let err = window.error { return err }
        if !window.unknownModels.isEmpty {
            return L10n.tr("Warning: %d unpriced models — totals may be incomplete.", window.unknownModels.count)
        }
        let countdown = isMonth ? CostBucketing.monthResetIn() : CostBucketing.todayResetIn()
        return L10n.tr("Resets in %@", countdown)
    }
}
