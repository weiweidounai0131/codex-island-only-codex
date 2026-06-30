import SwiftUI
import AppKit

/// Usage data row. The chrome (provider titles, footer chip + page dots +
/// sync status) lives in `PanelHeader` / `PanelFooter` so it stays fixed
/// while this row swipes between usage and cost screens.
///
/// Codex usage row. The app is single-provider now, so the old two-column
/// Claude/Codex split is replaced by one centered Codex chart group.
struct UsageView: View {
    @ObservedObject private var store = UsageStore.shared
    @ObservedObject private var pref = StylePref.shared

    private var style: ChartStyle { pref.style }

    var body: some View {
        ChartsBlock(color: IslandColor.codex, usage: store.codex,
                    style: style, seed: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

struct ChartsBlock: View {
    let color: Color
    let usage: AppUsage
    let style: ChartStyle
    let seed: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                ChartTile(style: style, color: color, labelKey: "5h",
                          window: usage.fiveHour, seed: seed)
                ChartTile(style: style, color: color, labelKey: "week",
                          window: usage.weekly, seed: seed + 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 12)
    }
}

struct ChartTile: View {
    let style: ChartStyle
    let color: Color
    let labelKey: String
    let window: WindowUsage
    let seed: Int
    @ObservedObject private var usageDisplay = UsageDisplayModeStore.shared

    /// Locked tile height across all 5 styles so the panel size is
    /// identical regardless of what the user picks.
    private static let tileHeight: CGFloat = 96

    var body: some View {
        let value = window.displayedFraction(mode: usageDisplay.mode) * 100   // 0-100
        let sub = subCaption()
        let label = L10n.tr(labelKey)

        Group {
            switch style {
            case .ring:    RingChart(value: value, color: color, label: label, sub: sub)
            case .bar:     BarChart(value: value, color: color, label: label, sub: sub)
            case .stepped: SteppedChart(value: value, color: color, label: label, sub: sub)
            case .numeric: NumericChart(value: value, color: color, label: label, sub: compactSubCaption())
            case .spark:   SparkChart(value: value, color: color, label: label, sub: sub, seed: seed)
            }
        }
        .id(style)
        // Blur + scale + opacity, all on the same strong ease-out at 220ms.
        // The blur masks the geometric mismatch between Ring and Bar so the
        // crossfade reads as one morph instead of two stacked objects.
        .transition(.chartSwap.animation(.chartSwap))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: Self.tileHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("%@, %d%%", label, Int(value)))
        .accessibilityValue(subCaption())
    }

    private func subCaption() -> String {
        if let r = window.resetAt {
            let delta = max(0, r.timeIntervalSinceNow)
            return L10n.tr("resets in %@", Duration.compact(delta))
        }
        // "no data" is our internal sentinel for "API returned null for this
        // window" — most commonly a brand-new 5h period before the first
        // OAuth call lands. Hide it so the tile reads as a passive
        // window-context cue (the "5h"/"week" header label communicates the
        // window type) instead of looking broken. Real errors still surface.
        if let err = window.error, err != "no data" {
            return err
        }
        return ""
    }

    private func compactSubCaption() -> String {
        if let r = window.resetAt {
            let delta = max(0, r.timeIntervalSinceNow)
            return "↻ " + Duration.compact(delta)
        }
        if let err = window.error, err != "no data" {
            return err
        }
        return ""
    }
}
