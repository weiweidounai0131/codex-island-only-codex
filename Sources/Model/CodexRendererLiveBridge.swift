import Foundation

enum CodexRendererLiveBridgeState: Equatable {
    case idle
    case attaching(processIdentifier: Int32)
    case attached(processIdentifier: Int32)
    case unavailable(processIdentifier: Int32, reason: String)
}

/// Owns the explicit Inspector attach used to install the CH surface.
///
/// The injected bridge keeps only a read-only notification subscription after
/// installation. The connection belongs to the explicitly launched Codex
/// process and is never opened by sending a signal to a stock launch.
@MainActor
final class CodexRendererLiveBridge {
    private let hudSource: String?
    private let bridgeSource: String?
    private var operation: Task<Void, Never>?
    private var processIdentifier: Int32?
    private var latestSnapshot: CodexCacheHitSnapshot?
    private var latestCreditsBalance: Double?
    private var didProjectInitialSnapshot = false
    private var blockedForProcess = false
    private var generation = 0
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var visibleThreadOperation: Task<Void, Never>?
    private var lastVisibleThreadRefresh = Date.distantPast

    private(set) var state: CodexRendererLiveBridgeState = .idle
    var onVisibleThreadID: ((String?) -> Void)?
    var onStateChange: ((CodexRendererLiveBridgeState) -> Void)?

    init(bundle: Bundle = .main) {
        hudSource = Self.loadResource(
            name: "CodexCacheHUD",
            bundle: bundle
        )
        bridgeSource = Self.loadResource(
            name: "CodexCacheHUDBridge",
            bundle: bundle
        )
    }

    func start(processIdentifier: Int32) {
        guard processIdentifier > 0 else { return }
        if self.processIdentifier == processIdentifier, state != .idle {
            return
        }

        cancelOperation()
        cancelRetry()
        self.processIdentifier = processIdentifier
        didProjectInitialSnapshot = false
        blockedForProcess = false
        retryAttempt = 0
        lastVisibleThreadRefresh = .distantPast
        transition(to: .attaching(processIdentifier: processIdentifier))
        launch(snapshot: latestSnapshot)
    }

    func update(snapshot: CodexCacheHitSnapshot?, creditsBalance: Double?) {
        guard latestSnapshot != snapshot || latestCreditsBalance != creditsBalance else { return }
        latestSnapshot = snapshot
        latestCreditsBalance = creditsBalance

        guard let processIdentifier, !blockedForProcess else { return }
        switch state {
        case .attached:
            guard let snapshot else { return }
            if didProjectInitialSnapshot {
                project(snapshot: snapshot, creditsBalance: creditsBalance)
            } else {
                launch(snapshot: snapshot)
            }
        case .unavailable:
            cancelRetry()
            transition(to: .attaching(processIdentifier: processIdentifier))
            launch(snapshot: snapshot)
        case .idle, .attaching:
            break
        }
    }

    /// Reconcile the visible Codex conversation independently from token
    /// changes. Switching tasks does not necessarily emit a token event, and
    /// the renderer notification manager is absent in some Codex releases.
    func refreshVisibleThread() {
        guard visibleThreadOperation == nil,
              let processIdentifier,
              !blockedForProcess,
              Date().timeIntervalSince(lastVisibleThreadRefresh) >= 2.5 else {
            return
        }
        guard case .attached = state else { return }

        lastVisibleThreadRefresh = Date()
        let currentGeneration = generation
        visibleThreadOperation = Task { [weak self] in
            do {
                let visibleThreadID = try await CodexRendererInspectorAttachment.visibleThreadID(
                    processIdentifier: processIdentifier
                )
                guard !Task.isCancelled else { return }
                self?.finishVisibleThread(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier,
                    visibleThreadID: visibleThreadID
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier,
                    error: error
                )
            }
        }
    }

    func stop() {
        let cleanupProcessIdentifier = processIdentifier
        let shouldDisable = {
            if case .attached = state { return true }
            return false
        }()
        let cleanupHUDSource = hudSource
        let cleanupBridgeSource = bridgeSource

        cancelOperation()
        cancelRetry()
        visibleThreadOperation?.cancel()
        visibleThreadOperation = nil
        processIdentifier = nil
        latestSnapshot = nil
        latestCreditsBalance = nil
        didProjectInitialSnapshot = false
        blockedForProcess = false
        retryAttempt = 0
        lastVisibleThreadRefresh = .distantPast
        transition(to: .idle)

        guard shouldDisable,
              let cleanupProcessIdentifier,
              let cleanupHUDSource,
              let cleanupBridgeSource else {
            return
        }

        // Best-effort cleanup when the user turns the setting off while
        // Codex remains open. A Codex exit simply makes this cycle fail.
        Task.detached {
            _ = try? await CodexRendererInspectorAttachment.install(
                processIdentifier: cleanupProcessIdentifier,
                hudSource: cleanupHUDSource,
                bridgeSource: cleanupBridgeSource,
                snapshotJSON: nil,
                enabled: false
            )
        }
    }

    private func launch(snapshot: CodexCacheHitSnapshot?) {
        guard operation == nil,
              let processIdentifier,
              let hudSource,
              let bridgeSource else {
            if hudSource == nil || bridgeSource == nil {
                transition(
                    to: .unavailable(
                        processIdentifier: processIdentifier ?? 0,
                        reason: "Cache HUD resources are missing."
                    )
                )
            }
            return
        }

        let currentGeneration = generation
        let projectedCreditsBalance = latestCreditsBalance
        let snapshotJSON = Self.snapshotJSON(snapshot, creditsBalance: projectedCreditsBalance)
        operation = Task { [weak self] in
            do {
                let visibleThreadID = try await CodexRendererInspectorAttachment.install(
                    processIdentifier: processIdentifier,
                    hudSource: hudSource,
                    bridgeSource: bridgeSource,
                    snapshotJSON: snapshotJSON,
                    enabled: true
                )
                guard !Task.isCancelled else { return }
                self?.finish(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier,
                    visibleThreadID: visibleThreadID,
                    projectedSnapshot: snapshot,
                    projectedCreditsBalance: projectedCreditsBalance
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier,
                    error: error
                )
            }
        }
    }

    private func project(snapshot: CodexCacheHitSnapshot, creditsBalance: Double?) {
        guard operation == nil,
              let processIdentifier,
              let snapshotJSON = Self.snapshotJSON(snapshot, creditsBalance: creditsBalance) else {
            return
        }

        let currentGeneration = generation
        let projectedCreditsBalance = creditsBalance
        operation = Task { [weak self] in
            do {
                let visibleThreadID = try await CodexRendererInspectorAttachment.projectSnapshot(
                    processIdentifier: processIdentifier,
                    snapshotJSON: snapshotJSON
                )
                guard !Task.isCancelled else { return }
                self?.finishProjection(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier,
                    visibleThreadID: visibleThreadID,
                    projectedSnapshot: snapshot,
                    projectedCreditsBalance: projectedCreditsBalance
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier,
                    error: error
                )
            }
        }
    }

    private func finish(
        generation: Int,
        processIdentifier: Int32,
        visibleThreadID: String?,
        projectedSnapshot: CodexCacheHitSnapshot?,
        projectedCreditsBalance: Double?
    ) {
        guard generation == self.generation,
              self.processIdentifier == processIdentifier else {
            return
        }
        operation = nil
        cancelRetry()
        retryAttempt = 0
        if projectedSnapshot != nil {
            didProjectInitialSnapshot = true
        }
        transition(to: .attached(processIdentifier: processIdentifier))
        onVisibleThreadID?(visibleThreadID)

        if let latestSnapshot {
            let dataChanged = latestSnapshot != projectedSnapshot
                || latestCreditsBalance != projectedCreditsBalance
            if dataChanged {
                if projectedSnapshot == nil || !didProjectInitialSnapshot {
                    launch(snapshot: latestSnapshot)
                } else {
                    project(snapshot: latestSnapshot, creditsBalance: latestCreditsBalance)
                }
            }
        }
    }

    private func finishProjection(
        generation: Int,
        processIdentifier: Int32,
        visibleThreadID: String?,
        projectedSnapshot: CodexCacheHitSnapshot,
        projectedCreditsBalance: Double?
    ) {
        guard generation == self.generation,
              self.processIdentifier == processIdentifier else {
            return
        }
        operation = nil
        cancelRetry()
        retryAttempt = 0
        transition(to: .attached(processIdentifier: processIdentifier))
        if let visibleThreadID {
            onVisibleThreadID?(visibleThreadID)
        }

        if let latestSnapshot,
           latestSnapshot != projectedSnapshot || latestCreditsBalance != projectedCreditsBalance {
            project(snapshot: latestSnapshot, creditsBalance: latestCreditsBalance)
        }
    }

    private func finishVisibleThread(
        generation: Int,
        processIdentifier: Int32,
        visibleThreadID: String?
    ) {
        guard generation == self.generation,
              self.processIdentifier == processIdentifier else {
            return
        }
        visibleThreadOperation = nil
        if let visibleThreadID {
            onVisibleThreadID?(visibleThreadID)
        }
    }

    private func fail(
        generation: Int,
        processIdentifier: Int32,
        error: Error
    ) {
        guard generation == self.generation,
              self.processIdentifier == processIdentifier else {
            return
        }
        operation = nil
        visibleThreadOperation?.cancel()
        visibleThreadOperation = nil
        if let inspectorError = error as? CodexInspectorError,
           case .noExplicitRendererEndpoint = inspectorError {
            // A process without an explicit endpoint will not gain one
            // during its lifetime. Avoid retrying on every local file poll;
            // the next Codex restart calls start() with a fresh PID.
            blockedForProcess = true
        }
        transition(
            to: .unavailable(
                processIdentifier: processIdentifier,
                reason: error.localizedDescription
            )
        )
        scheduleRetry()
    }

    private func cancelOperation() {
        generation += 1
        operation?.cancel()
        operation = nil
        visibleThreadOperation?.cancel()
        visibleThreadOperation = nil
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func scheduleRetry() {
        guard retryTask == nil,
              !blockedForProcess,
              let processIdentifier else {
            return
        }

        let delays: [UInt64] = [1_000_000_000, 3_000_000_000, 8_000_000_000]
        let delay = delays[min(retryAttempt, delays.count - 1)]
        retryAttempt = min(retryAttempt + 1, delays.count - 1)
        let currentGeneration = generation
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generation == currentGeneration,
                  self.processIdentifier == processIdentifier,
                  !self.blockedForProcess else {
                return
            }
            if case .attached = self.state {
                return
            }
            self.retryTask = nil
            self.transition(to: .attaching(processIdentifier: processIdentifier))
            self.launch(snapshot: self.latestSnapshot)
        }
    }

    private func transition(to nextState: CodexRendererLiveBridgeState) {
        guard state != nextState else { return }
        state = nextState
        onStateChange?(nextState)
    }

    private static func snapshotJSON(
        _ snapshot: CodexCacheHitSnapshot?,
        creditsBalance: Double?
    ) -> String? {
        guard let snapshot else { return nil }
        guard let cacheHitRatePercent = snapshot.cacheHitRatePercent else {
            return nil
        }
        var object: [String: Any] = [
            "threadId": snapshot.sessionID,
            "turnId": snapshot.turnID,
            "inputTokens": snapshot.inputTokens,
            "cachedInputTokens": snapshot.cachedInputTokens,
            "cacheWriteInputTokens": snapshot.cacheWriteInputTokens,
            "outputTokens": snapshot.outputTokens,
            "totalTokens": snapshot.totalTokens,
            "cacheHitRatePercent": cacheHitRatePercent,
            "creditsBalance": creditsBalance.map { $0 as Any } ?? NSNull()
        ]
        if let contextUsedTokens = snapshot.contextUsedTokens {
            object["contextUsedTokens"] = contextUsedTokens
        }
        if let contextWindowTokens = snapshot.contextWindowTokens {
            object["contextWindowTokens"] = contextWindowTokens
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func loadResource(name: String, bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
