import SwiftUI
import AppKit

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var alwaysShow = AlwaysShowUsageStore.shared
    @ObservedObject private var taskActivity = CodexTaskActivityStore.shared
    @State private var hovering = false
    @State private var contentVisible = false
    @State private var pillsVisible = false
    @State private var pulseToken: UUID?

    /// Image decode from disk is ~150µs per call. Computed properties
    /// re-decoded the logo every render. Cache once on appear.
    @State private var openaiLogo: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            // Only the rotating loading sweep needs per-frame re-renders
            // (its angle is a function of time). Everything else animates
            // via withAnimation springs paced by display sync, so wrapping
            // the whole tree in TimelineView would re-build every overlay
            // and every gesture closure 120 times per second — competing
            // with the spring for main-thread budget and showing up as
            // hover-spring jank.
            ZStack {
                GlowLayer(
                    isExpanded: model.state == .expanded,
                    hovering: hovering,
                    shape: islandShape
                )

                if model.state == .expanded {
                    ExpandedView(model: model)
                        .opacity(contentVisible ? 1 : 0)
                        // Slide down from -8 → 0 on enter pairs with the
                        // 100ms→180ms opacity delay set in onHover. On
                        // exit the offset never matters because the
                        // content fully fades before the shape shrinks.
                        .offset(y: contentVisible ? 0 : -8)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .allowsHitTesting(contentVisible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: model.size.width, height: model.size.height)
            .background {
                    // Frosted halo. ultraThinMaterial is a backdrop blur of
                    // whatever desktop content is behind the window. Lives
                    // in .background AFTER .frame so it doesn't push the
                    // ZStack's layout box larger than model.size — earlier
                    // attempts that put the halo as a sibling inside the
                    // ZStack with its own oversized .frame ended up
                    // expanding the parent bounds, throwing the logo
                    // overlays off and breaking the compact pill alignment
                    // with the physical notch.
                    //
                    // .padding(-9) extends only the rendering by 9pt past
                    // the silhouette on every side, no layout impact.
                    // Opacity tied to contentVisible so it fades alongside
                    // the panel content (220ms after hover-in, immediately
                    // on hover-out) and the .frame here tracks model.size,
                    // so the halo grows/shrinks with the spring morph.
                    islandShape
                        .fill(.ultraThinMaterial)
                        .padding(-9)
                        .blur(radius: 8)
                        .opacity(contentVisible ? 0.55 : 0)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    LogoOverlay(
                        image: openaiLogo,
                        color: IslandColor.codex,
                        provider: .codex,
                        edge: .leading,
                        edgePadding: logoEdgePadding,
                        topPadding: max(0, (model.notch.height - 20) / 2),
                        isWorking: taskActivity.state.inProgressCount > 0
                    )
                }
                .overlay(alignment: .topLeading) {
                    if taskActivity.state.isVisible {
                        TaskProgressOverlay(
                            state: taskActivity.state,
                            useCompactEmptyLabels: model.notch.hasNotch && model.state != .expanded
                        )
                            .padding(.leading, taskProgressLeadingPadding)
                            .padding(.top, max(0, (model.notch.height - 14) / 2))
                            .opacity(model.state == .expanded && !contentVisible ? 0 : 1)
                            .animation(.strongEaseOut, value: contentVisible)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.state != .compact {
                        PeekPillOverlay(
                            provider: .codex,
                            topPadding: max(0, (model.notch.height - 14) / 2),
                            pillsVisible: pillsVisible
                        )
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // Utility control, not dashboard status. Keep it in a
                    // quiet corner so the footer remains about live data.
                    if model.state == .expanded {
                        SettingsButton()
                            .opacity(contentVisible ? 1 : 0)
                            .padding(6)
                    }
                }
                .contentShape(islandShape)
                .onTapGesture {
                    // Cmd-click cycles the visualization style of whichever
                    // page is active. Usage rotates Ring/Bar/Stepped/Numeric/
                    // Spark; cost rotates USD/VALUE/TOKENS/TREND. Overview
                    // is fixed to year-to-date.
                    if NSEvent.modifierFlags.contains(.command) {
                        switch ScreenPref.shared.screen {
                        case .usage: StylePref.shared.cycle()
                        case .cost:  CostStylePref.shared.cycle()
                        case .overview: return
                        }
                        return
                    }
                    // Plain click: enter the full panel. Works from .peek
                    // (the common case after hover) or .compact (cold click).
                    // Pills travel outward with the growing shape under the
                    // single openMorph spring, then quietly retire after the
                    // expanded content has settled.
                    guard model.state == .peek || model.state == .compact else { return }
                    withAnimation(.openMorph) {
                        model.setState(.expanded)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        guard model.state == .expanded else { return }
                        withAnimation(.strongEaseOut) {
                            contentVisible = true
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeIn(duration: 0.18)) {
                            pillsVisible = false
                        }
                    }
                }
                .onHover { h in
                    hovering = h
                    if h {
                        // Trackpad tap on hover-in. .levelChange is closer to
                        // a volume-key tick than the .generic notification
                        // pattern. No-op if haptics are off.
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .levelChange, performanceTime: .now
                        )
                        // PEEK ENTER: shape morphs out to peek width. Pills
                        // fade in 60ms later so the eye sees the shape commit
                        // first, then content arrives. Hover does NOT open
                        // the full panel — that requires a click.
                        if model.state == .compact {
                            withAnimation(.openMorph) {
                                model.setState(.peek)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                                guard model.state == .peek else { return }
                                withAnimation(.easeOut(duration: 0.18)) {
                                    pillsVisible = true
                                }
                            }
                        }
                    } else {
                        // EXIT: pills fade first (unless we're pinning peek),
                        // then the shape settles at the rest state — `.compact`
                        // normally, `.peek` under always-show.
                        if !alwaysShow.enabled {
                            withAnimation(.easeOut(duration: 0.08)) {
                                pillsVisible = false
                            }
                        }
                        withAnimation(.easeOut(duration: 0.10)) {
                            contentVisible = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                            guard !hovering else { return }
                            // Re-read restState here — the user may have flipped
                            // the always-show toggle during the 100ms wait, and
                            // a captured-at-creation-time `target` would settle
                            // at the wrong state for them.
                            let target = restState
                            if model.state != target {
                                withAnimation(.closeMorph) {
                                    model.setState(target)
                                }
                            }
                            // Coming out of `.expanded` under always-show, the
                            // pills were hidden by the open-panel branch — bring
                            // them back as the shape resettles at peek.
                            if alwaysShow.enabled && !pillsVisible {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    pillsVisible = true
                                }
                            }
                        }
                    }
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("CodexIsland panel"))
        .accessibilityHint(accessibilityHintForState)
        .onAppear {
            if openaiLogo == nil {
                openaiLogo = Bundle.main.url(forResource: "openai_logo", withExtension: "pdf")
                    .flatMap { NSImage(contentsOf: $0) }
            }
            // Snap to peek on launch when the user has opted into always-show.
            // No animation here — the window is just becoming visible, so the
            // user sees the silhouette appear already at peek width rather
            // than morphing out under their gaze.
            if alwaysShow.enabled && model.state == .compact {
                model.setState(.peek)
                pillsVisible = true
            }
        }
        .onChange(of: alwaysShow.enabled) { enabled in
            // Live toggle — defer to the user's current interaction. If they
            // happen to be hovering, the hover state machine owns the morph
            // and will land on the new rest state on hover-out. If the panel
            // is expanded, leave it alone for the same reason.
            guard !hovering, model.state != .expanded else { return }
            if enabled {
                if model.state == .compact {
                    withAnimation(.openMorph) {
                        model.setState(.peek)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        guard model.state == .peek, !hovering else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            pillsVisible = true
                        }
                    }
                }
            } else {
                if model.state == .peek {
                    withAnimation(.easeOut(duration: 0.08)) {
                        pillsVisible = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        // Re-check `alwaysShow.enabled` — if the user toggled
                        // back on inside the 100ms wait, leave the peek state
                        // alone instead of fighting their newer intent.
                        guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
                        withAnimation(.closeMorph) {
                            model.setState(.compact)
                        }
                    }
                }
            }
        }
        .onReceive(AlertEngine.shared.$pulseEvent) { event in
            guard let event, event.id != pulseToken else { return }
            pulseToken = event.id
            handlePulse(event)
            // Consume the event so a re-emission with the same id doesn't
            // re-trigger; the engine writes a fresh PulseEvent for each new
            // crossing tick.
            AlertEngine.shared.pulseEvent = nil
        }
    }

    /// Force-extends the island into peek state for ~4s when the alert
    /// engine signals a fresh threshold crossing. Suppressed when the panel
    /// is already expanded — the user is already looking at the data.
    private func handlePulse(_ event: AlertEngine.PulseEvent) {
        guard model.state != .expanded else { return }

        if model.state == .compact {
            withAnimation(.openMorph) {
                model.setState(.peek)
            }
            // Match the hover-in cadence so the pulse looks identical to a
            // user-initiated peek: shape commits first, content follows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard model.state == .peek else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    pillsVisible = true
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            // If the user is hovering or has expanded the panel meanwhile,
            // don't fight their state — let their interaction own the peek
            // lifecycle from here. Under always-show, `.peek` IS the rest
            // state, so the pulse just resolves into the steady-state pill
            // rather than collapsing back to compact.
            guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                pillsVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                // Mirror the outer 4-second guard — if always-show flipped on
                // during the tiny inner wait, leave the peek state alone.
                guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
                withAnimation(.closeMorph) {
                    model.setState(.compact)
                }
            }
        }
    }

    private var restState: IslandModel.State {
        alwaysShow.enabled ? .peek : .compact
    }

    private var islandShape: IslandShape {
        IslandShape()
    }

    private var accessibilityHintForState: String {
        switch model.state {
        case .compact:
            return alwaysShow.enabled
                ? L10n.tr("Click to expand. Command-click to cycle visualization.")
                : L10n.tr("Hover to peek usage. Click to expand. Command-click to cycle visualization.")
        case .peek:     return L10n.tr("Click to expand. Command-click to cycle visualization.")
        case .expanded:
            return ScreenPref.shared.screen == .overview
                ? L10n.tr("Swipe to change pages.")
                : L10n.tr("Command-click to cycle visualization.")
        }
    }

    /// Logo's distance from the silhouette's leading edge. Codex-only mode
    /// keeps the logo at the far left in both compact and peek states; only
    /// the island width changes.
    private var logoEdgePadding: CGFloat {
        9
    }

    /// Keep x/y inside the open black area after the 20pt Codex logo and
    /// before the trailing quota pill. The empty-state label is wider, so
    /// give it a smaller but still readable 8pt gap from the logo.
    private var taskProgressLeadingPadding: CGFloat {
        let isEmpty = taskActivity.state.completedCount == 0
            && taskActivity.state.inProgressCount == 0
        return logoEdgePadding + 20 + (isEmpty ? 8 : 20)
    }
}

/// Silhouette + halo. Bundles every layer whose
/// appearance depends on alert severity or the Low Power Mode event
/// predicate, so a UsageStore/AlertEngine/CostStore emission only
/// invalidates this child's body — not the root view's overlays,
/// gestures, or expanded-content branch.
private struct GlowLayer: View {
    let isExpanded: Bool
    let hovering: Bool
    let shape: IslandShape

    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var costStore = CostStore.shared
    @ObservedObject private var lowPower = LowPowerModeStore.shared
    @ObservedObject private var alerts = AlertEngine.shared
    var body: some View {
        ZStack {
            shape
                .fill(.black)
                .overlay {
                    shape
                        .strokeBorder(
                            .white.opacity(isExpanded ? 0.12 : 0),
                            lineWidth: 0.5
                        )
                }
                // Halo follows LPM's event predicate: under LPM it's
                // suppressed at rest and lights up only on refresh,
                // hover, or an active alert. Off-LPM it stays at the
                // ambient 0.35 the way it always has.
                .shadow(
                    color: glowColor.opacity(
                        lowPower.effectiveEnabled ? (glowEventActive ? 0.35 : 0) : 0.35
                    ),
                    radius: 14, y: 0
                )
                .animation(.easeInOut(duration: 0.25), value: glowEventActive)
                // 0.45s cross-fade so a threshold crossing (e.g. 79%→80%)
                // doesn't visibly snap the hue from cobalt to amber.
                .animation(.easeInOut(duration: 0.45), value: alerts.severity)
                .shadow(
                    color: isExpanded ? .black.opacity(0.5) : .clear,
                    radius: 20, y: 10
                )
        }
    }

    /// Under Low Power Mode the halo is gated on this predicate: the user
    /// sees an event glow only while something is happening (a fetch is in
    /// flight, the cursor is hovering, or an alert is active). Off-LPM the
    /// ambient halo remains visible.
    private var glowEventActive: Bool {
        hovering
            || usageStore.loading
            || costStore.loading
            || alerts.severity != .none
    }

    /// Silhouette glow color. Cobalt is the ambient default; alert
    /// thresholds replace it with amber/red so the user gets the signal
    /// passively, even before hovering. All three share the same opacity
    /// so the glow's visual weight is constant — only the hue signals
    /// severity.
    private var glowColor: Color {
        switch alerts.severity {
        case .none:     return IslandColor.cobalt
        case .warning:  return IslandColor.alertAmber
        case .critical: return IslandColor.alertRed
        }
    }
}

/// Resident/expanded reminder for Codex conversations. It occupies the open
/// black area after the logo and leaves the trailing quota pill unchanged.
private struct TaskProgressOverlay: View {
    let state: CodexTaskActivityState
    let useCompactEmptyLabels: Bool

    var body: some View {
        Group {
            if state.completedCount == 0, state.inProgressCount == 0 {
                HStack(spacing: 1) {
                    Text(useCompactEmptyLabels ? "D" : L10n.tr("Completed"))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(verbatim: "/")
                        .foregroundStyle(.white.opacity(0.42))
                    Text(useCompactEmptyLabels ? "L" : L10n.tr("In progress"))
                        .foregroundStyle(IslandColor.codex)
                }
            } else {
                HStack(spacing: 1) {
                    RollingNumber(
                        value: state.completedCount,
                        color: .white.opacity(0.86)
                    )
                    Text(verbatim: "/")
                        .foregroundStyle(.white.opacity(0.42))
                    RollingNumber(
                        value: state.inProgressCount,
                        color: IslandColor.codex
                    )
                }
            }
        }
        .font(Typography.bodyNumber)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .help(L10n.tr("Codex tasks: completed / in progress"))
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
    }

    private var accessibilityLabel: String {
        if state.completedCount == 0, state.inProgressCount == 0 {
            return L10n.tr("Codex tasks: completed / in progress")
        }
        return L10n.tr(
            "Codex tasks: %d completed, %d in progress",
            state.completedCount,
            state.inProgressCount
        )
    }
}

/// A single x/y digit group that rolls vertically when its value changes.
/// Increases enter from above; decreases enter from below.
struct RollingNumber: View {
    let value: Int
    let color: Color

    private let rollHeight: CGFloat = 14
    @State private var previousValue: Int?
    @State private var outgoingValue: Int?
    @State private var incomingOffset: CGFloat = 0
    @State private var outgoingOffset: CGFloat = 0
    @State private var isRolling = false
    @State private var animationToken = UUID()

    var body: some View {
        ZStack {
            if isRolling, let outgoingValue {
                Text(verbatim: "\(outgoingValue)")
                    .foregroundStyle(color)
                    .offset(y: outgoingOffset)
            }

            Text(verbatim: "\(value)")
                .foregroundStyle(color)
                .offset(y: isRolling ? incomingOffset : 0)
        }
        .font(Typography.bodyNumber)
        .fixedSize()
        .frame(minWidth: 7, minHeight: rollHeight, maxHeight: rollHeight)
        .clipped()
        .onAppear {
            previousValue = value
        }
        .onChange(of: value) { newValue in
            let oldValue = previousValue ?? value
            previousValue = newValue
            guard oldValue != newValue else { return }
            startRoll(from: oldValue, to: newValue)
        }
    }

    private func startRoll(from oldValue: Int, to newValue: Int) {
        let entersFromTop = newValue > oldValue
        let token = UUID()
        animationToken = token
        outgoingValue = oldValue
        isRolling = true
        incomingOffset = entersFromTop ? -rollHeight : rollHeight
        outgoingOffset = 0

        withAnimation(.countRoll) {
            incomingOffset = 0
            outgoingOffset = entersFromTop ? rollHeight : -rollHeight
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard animationToken == token else { return }
            isRolling = false
            outgoingValue = nil
            incomingOffset = 0
            outgoingOffset = 0
        }
    }
}

/// Per-provider brand logo overlay. Observes only ProviderVisibilityStore
/// so a UsageStore/CostStore tick doesn't re-render the logo image or
/// re-evaluate its accessibility label.
private struct LogoOverlay: View {
    let image: NSImage?
    let color: Color
    let provider: AlertEngine.Provider
    let edge: Edge.Set
    let edgePadding: CGFloat
    let topPadding: CGFloat
    let isWorking: Bool

    @ObservedObject private var visibility = ProviderVisibilityStore.shared

    var body: some View {
        // Hidden providers fully drop out — header / peek pill / chrome
        // are gated identically. `.opacity(isVisible ? 1 : 0)` keeps the
        // view in the layout (so other overlays don't reflow) but makes
        // it invisible, and the explicit `.animation(.openMorph, value:)`
        // pairs the chrome fade with the panel layout swap when the user
        // toggles a provider in Settings.
        if let image {
            Group {
                if isWorking {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        logoImage(image)
                            .rotationEffect(.degrees(rotation(at: context.date)))
                    }
                } else {
                    logoImage(image)
                }
            }
            .frame(width: 20, height: 20)
            .padding(edge, edgePadding)
            .padding(.top, topPadding)
            .opacity(isVisible ? 1 : 0)
            .animation(.openMorph, value: isVisible)
            .accessibilityLabel(
                isVisible
                    ? (isWorking ? L10n.tr("%@, working", providerLabel) : providerLabel)
                    : L10n.tr("%@ (hidden)", providerLabel)
            )
            .accessibilityHidden(!isVisible)
        }
    }

    private func logoImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
    }

    private func rotation(at date: Date) -> Double {
        let period = 1.2
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period)
        return phase / period * 360
    }

    private var isVisible: Bool {
        visibility.effectiveVisible(provider: provider)
    }

    private var providerLabel: String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "OpenAI"
        }
    }
}

/// Per-provider peek pill overlay. Observes ProviderVisibilityStore,
/// UsageStore, and AlertEngine — but not CostStore, so a Codex log
/// scan completing doesn't re-render the pill that has no cost data
/// in it.
private struct PeekPillOverlay: View {
    let provider: AlertEngine.Provider
    let topPadding: CGFloat
    let pillsVisible: Bool

    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var alerts = AlertEngine.shared
    @ObservedObject private var quotaMode = CodexQuotaModeStore.shared

    var body: some View {
        let window = currentWindow
        NotchPeekPill(
            usage: window,
            loading: usageStore.loading,
            tint: tint,
            alignment: provider == .claude ? .leading : .trailing,
            leadingUsage: weeklyPeekWindow,
            severity: severity
        )
        .padding(provider == .claude ? .leading : .trailing, 14)
        .padding(.top, topPadding)
        // Two opacity bindings stack:
        //   - `pillsVisible` is the peek lifecycle (hover-in / hover-out).
        //   - `isVisible` is the user's settings toggle.
        // Both must be 1 to render. Animating `isVisible` with the same
        // openMorph spring as the panel layout keeps the toggle fade in
        // lockstep with the rest of the chrome.
        .opacity((pillsVisible && isVisible) ? 1 : 0)
        .animation(.openMorph, value: isVisible)
        .offset(x: pillsVisible ? 0 : (provider == .claude ? -6 : 6))
        .allowsHitTesting(false)
        .accessibilityLabel(peekLabel(for: window, provider: providerLabel))
        // Mirror the visual opacity gate exactly — both `pillsVisible` and
        // `isVisible` must be true for the pill to render. Keying the
        // accessibility hide on only `isVisible` lets VoiceOver reach a
        // pill that is visually invisible during the peek-out lifecycle.
        .accessibilityHidden(!(pillsVisible && isVisible))
    }

    private var isVisible: Bool {
        visibility.effectiveVisible(provider: provider)
    }

    private var currentWindow: WindowUsage {
        switch provider {
        case .claude: return usageStore.claude.fiveHour
        case .codex:  return usageStore.codex.primaryWindow(mode: quotaMode.mode)
        }
    }

    private var weeklyPeekWindow: WindowUsage? {
        guard provider == .codex, quotaMode.mode == .hourlyAndWeekly else { return nil }
        let windows = usageStore.codex.displayWindows(mode: .hourlyAndWeekly)
        guard windows.count > 1 else { return nil }
        return windows[1].window
    }

    private var severity: AlertEngine.Severity {
        switch provider {
        case .claude: return alerts.claudeSeverity
        case .codex:  return alerts.codexSeverity
        }
    }

    private var tint: Color {
        switch provider {
        case .claude: return IslandColor.claude
        case .codex:  return IslandColor.codex
        }
    }

    private var providerLabel: String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    private func peekLabel(for window: WindowUsage, provider: String) -> String {
        if window.error != nil && window.usedPercent == 0 {
            return L10n.tr("%@: no data for 5-hour window", provider)
        }
        let mode = UsageDisplayModeStore.shared.mode
        let pct = window.displayedPercentInt(mode: mode)
        guard let resetAt = window.resetAt else {
            return mode == .used
                ? L10n.tr("%@: %d percent of 5-hour window used", provider, pct)
                : L10n.tr("%@: %d percent of 5-hour window remaining", provider, pct)
        }
        let remaining = max(0, resetAt.timeIntervalSinceNow)
        let resetPhrase: String = remaining >= 3600
            ? L10n.tr("resets in %d hours", Int((remaining / 3600).rounded(.down)))
            : L10n.tr("resets in %d minutes", max(1, Int((remaining / 60).rounded(.down))))
        return mode == .used
            ? L10n.tr("%@: %d percent of 5-hour window used, %@", provider, pct, resetPhrase)
            : L10n.tr("%@: %d percent of 5-hour window remaining, %@", provider, pct, resetPhrase)
    }
}
