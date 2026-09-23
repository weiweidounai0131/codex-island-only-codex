import Combine
import Foundation

@MainActor
final class CodexCreditBalanceDisplayStore: ObservableObject {
    static let shared = CodexCreditBalanceDisplayStore()

    private static let activeKey = "MacIsland.codexCreditDisplay.active"
    private static let resetAtKey = "MacIsland.codexCreditDisplay.resetAt"

    @Published private(set) var isShowingCreditsBalance: Bool

    private var activationResetAt: Date?
    private var usageCancellable: AnyCancellable?
    private var taskActivityCancellable: AnyCancellable?
    private var resetTimer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        isShowingCreditsBalance = defaults.bool(forKey: Self.activeKey)
        activationResetAt = defaults.object(forKey: Self.resetAtKey) as? Date
    }

    func start() {
        guard usageCancellable == nil, taskActivityCancellable == nil else { return }

        if let activationResetAt, activationResetAt <= Date() {
            deactivate()
            UsageStore.shared.refresh()
        } else if isShowingCreditsBalance {
            scheduleReset(for: activationResetAt)
        }

        usageCancellable = UsageStore.shared.$codex.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        taskActivityCancellable = CodexTaskActivityStore.shared.$state.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcile()
    }

    func stop() {
        usageCancellable?.cancel()
        usageCancellable = nil
        taskActivityCancellable?.cancel()
        taskActivityCancellable = nil
        resetTimer?.invalidate()
        resetTimer = nil
    }

    private func reconcile() {
        if isShowingCreditsBalance,
           let activationResetAt,
           activationResetAt <= Date() {
            deactivate()
            UsageStore.shared.refresh()
            return
        }
        guard let hourlyWindow = UsageStore.shared.codex.hourlyWindow else { return }

        if isShowingCreditsBalance, hasWindowReset(hourlyWindow) {
            deactivate()
            UsageStore.shared.refresh()
            return
        }

        if isShowingCreditsBalance {
            if activationResetAt == nil, let resetAt = hourlyWindow.resetAt {
                activationResetAt = resetAt
                UserDefaults.standard.set(resetAt, forKey: Self.resetAtKey)
            }
            scheduleReset(for: activationResetAt)
            return
        }

        guard hourlyWindow.usedPercent >= 1,
              CodexTaskActivityStore.shared.state.inProgressCount > 0,
              hourlyWindow.resetAt.map({ $0 > Date() }) ?? true else {
            return
        }

        activate(until: hourlyWindow.resetAt)
    }

    private func hasWindowReset(_ window: WindowUsage) -> Bool {
        if let activationResetAt, activationResetAt <= Date() {
            return true
        }
        if let currentResetAt = window.resetAt, currentResetAt <= Date() {
            return true
        }
        guard let activationResetAt,
              let currentResetAt = window.resetAt else {
            return window.usedPercent < 1
        }
        return abs(currentResetAt.timeIntervalSince(activationResetAt)) > 1
    }

    private func activate(until resetAt: Date?) {
        isShowingCreditsBalance = true
        activationResetAt = resetAt
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.activeKey)
        if let resetAt {
            defaults.set(resetAt, forKey: Self.resetAtKey)
        } else {
            defaults.removeObject(forKey: Self.resetAtKey)
        }
        scheduleReset(for: resetAt)
    }

    private func deactivate() {
        resetTimer?.invalidate()
        resetTimer = nil
        isShowingCreditsBalance = false
        activationResetAt = nil
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.activeKey)
        defaults.removeObject(forKey: Self.resetAtKey)
    }

    private func scheduleReset(for resetAt: Date?) {
        resetTimer?.invalidate()
        resetTimer = nil
        guard let resetAt else { return }
        let delay = resetAt.timeIntervalSinceNow
        guard delay > 0 else { return }

        resetTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isShowingCreditsBalance,
                      let activationResetAt = self.activationResetAt,
                      abs(activationResetAt.timeIntervalSince(resetAt)) < 1 else {
                    return
                }
                self.deactivate()
                UsageStore.shared.refresh()
            }
        }
    }
}
