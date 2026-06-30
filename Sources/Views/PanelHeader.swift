import SwiftUI

/// Codex title row. Lives outside `PagedContent` so it stays fixed while
/// the data area swipes between usage/cost/overview screens.
///
/// Plan tags ("MAX" / "PLUS") are sourced from `UsageStore` since the
/// subscription tier is a property of the account, not the current page.
struct PanelHeader: View {
    let notch: NotchInfo
    @ObservedObject private var usageStore = UsageStore.shared

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: notch.width)
            providerTitle(name: "Codex", tag: usageStore.codex.plan?.uppercased(),
                          color: IslandColor.codex, alignment: .trailing)
        }
        .frame(height: 22)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, min(14, max(0, notch.height - 22 - 4)))
    }

    @ViewBuilder
    private func providerTitle(
        name: String,
        tag: String?,
        color: Color,
        alignment: HorizontalAlignment
    ) -> some View {
        // Push past where the overlay logo lands: 9 leading + 20 logo + 8 gap.
        let logoOffset: CGFloat = 9 + 20 + 8

        let content = HStack(spacing: 8) {
            Text(name)
                .font(Typography.providerTitle)
                .foregroundStyle(.white)
            if let tag {
                Text(tag)
                    .font(Typography.chip)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
            }
        }

        if alignment == .leading {
            HStack {
                content.padding(.leading, logoOffset)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Spacer(minLength: 0)
                content.padding(.trailing, logoOffset)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
