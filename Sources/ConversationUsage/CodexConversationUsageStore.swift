import Combine
import Foundation

enum CodexConversationUsageStatus: Equatable {
    case disabled
    case waitingForCodex
    case reading
    case waitingForRendererMapping
    case ready
    case noData
    case rendererUnavailable
}

/// Coordinates the local CH reader with the stock Codex lifecycle.
///
/// The store deliberately exposes snapshots by session but only publishes a
/// visible snapshot after an approved renderer adapter binds a session id.
/// Until that mapping exists, data remains available for diagnostics but is
/// not eligible for display, which is the PRD's fail-closed rule.
@MainActor
final class CodexConversationUsageStore: ObservableObject {
    static let shared = CodexConversationUsageStore()

    @Published private(set) var status: CodexConversationUsageStatus = .disabled
    @Published private(set) var snapshotsBySessionID: [String: [CodexCacheHitSnapshot]] = [:]
    @Published private(set) var visibleSnapshot: CodexCacheHitSnapshot?

    private let preference: CodexConversationUsagePreference
    private let reader: CodexCacheHitReader
    private let processWatcher: CodexProcessWatching
    private let rendererBridge: CodexRendererLiveBridge
    private var preferenceCancellable: AnyCancellable?
    private var pollTimer: Timer?
    private var started = false
    private var refreshGeneration = 0
    private var codexRunning = false
    private var visibleSessionID: String?
    private var rendererUnavailable = false

    init(
        preference: CodexConversationUsagePreference? = nil,
        reader: CodexCacheHitReader = CodexCacheHitReader(),
        processWatcher: CodexProcessWatching? = nil,
        rendererBridge: CodexRendererLiveBridge? = nil
    ) {
        self.preference = preference ?? CodexConversationUsagePreference.shared
        self.reader = reader
        self.processWatcher = processWatcher ?? CodexProcessWatcher()
        self.rendererBridge = rendererBridge ?? CodexRendererLiveBridge()
        self.rendererBridge.onVisibleThreadID = { [weak self] threadID in
            self?.bindVisibleSession(threadID)
        }
        self.rendererBridge.onStateChange = { [weak self] state in
            self?.handleRendererState(state)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        preferenceCancellable = preference.$enabled.sink { [weak self] enabled in
            Task { @MainActor [weak self] in
                self?.applyPreference(enabled)
            }
        }
        applyPreference(preference.enabled)
    }

    func stop() {
        guard started || status != .disabled else { return }
        started = false
        preferenceCancellable?.cancel()
        preferenceCancellable = nil
        stopPolling()
        processWatcher.onStateChange = nil
        processWatcher.stop()
        rendererBridge.stop()
        refreshGeneration += 1
        codexRunning = false
        visibleSessionID = nil
        rendererUnavailable = false
        visibleSnapshot = nil
        snapshotsBySessionID = [:]
        status = .disabled
    }

    /// Called only by a future approved renderer adapter after it has proved
    /// which visible Codex thread owns the current footer.
    func bindVisibleSession(_ sessionID: String?) {
        visibleSessionID = sessionID
        updateVisibleSnapshot()
    }

    func refresh() {
        guard started, preference.enabled, codexRunning else { return }
        let generation = refreshGeneration
        let reader = self.reader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshots = reader.read()
            DispatchQueue.main.async {
                guard let self,
                      self.started,
                      self.preference.enabled,
                      self.codexRunning,
                      self.refreshGeneration == generation else {
                    return
                }
                self.apply(snapshots)
            }
        }
    }

    private func applyPreference(_ enabled: Bool) {
        guard started else { return }
        if enabled {
            processWatcher.onStateChange = { [weak self] state in
                self?.handleProcessState(state)
            }
            processWatcher.start()
        } else {
            processWatcher.onStateChange = nil
            processWatcher.stop()
            rendererBridge.stop()
            stopPolling()
            refreshGeneration += 1
            codexRunning = false
            rendererUnavailable = false
            visibleSessionID = nil
            visibleSnapshot = nil
            snapshotsBySessionID = [:]
            status = .disabled
        }
    }

    private func handleProcessState(_ state: CodexProcessWatcherState) {
        switch state {
        case .stopped:
            codexRunning = false
            rendererUnavailable = false
            stopPolling()
            rendererBridge.stop()
            visibleSessionID = nil
            visibleSnapshot = nil
            snapshotsBySessionID = [:]
            status = preference.enabled ? .waitingForCodex : .disabled
        case .waitingForCodex:
            codexRunning = false
            rendererUnavailable = false
            stopPolling()
            rendererBridge.stop()
            visibleSessionID = nil
            visibleSnapshot = nil
            snapshotsBySessionID = [:]
            status = .waitingForCodex
        case .running(let processIdentifier):
            codexRunning = true
            rendererUnavailable = false
            status = .reading
            rendererBridge.start(processIdentifier: processIdentifier)
            startPolling()
            refresh()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func apply(_ snapshots: [CodexCacheHitSnapshot]) {
        snapshotsBySessionID = Dictionary(grouping: snapshots, by: \.sessionID)
            .mapValues { $0.sorted { $0.timestamp > $1.timestamp } }
        updateVisibleSnapshot()
        rendererBridge.update(snapshot: visibleSnapshot)

        if rendererUnavailable {
            status = .rendererUnavailable
        } else if visibleSnapshot != nil {
            status = .ready
        } else if snapshotsBySessionID.isEmpty {
            status = .noData
        } else {
            status = .waitingForRendererMapping
        }
    }

    private func updateVisibleSnapshot() {
        guard let visibleSessionID else {
            visibleSnapshot = nil
            return
        }
        visibleSnapshot = snapshotsBySessionID[visibleSessionID]?.first
    }

    private func handleRendererState(_ state: CodexRendererLiveBridgeState) {
        switch state {
        case .unavailable:
            rendererUnavailable = true
            if preference.enabled {
                status = .rendererUnavailable
            }
        case .attaching, .attached:
            rendererUnavailable = false
        case .idle:
            rendererUnavailable = false
        }
    }
}
