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
    private var didProjectInitialSnapshot = false
    private var blockedForProcess = false
    private var generation = 0

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
        self.processIdentifier = processIdentifier
        didProjectInitialSnapshot = false
        blockedForProcess = false
        transition(to: .attaching(processIdentifier: processIdentifier))
        launch(snapshot: latestSnapshot)
    }

    func update(snapshot: CodexCacheHitSnapshot?) {
        guard latestSnapshot != snapshot else { return }
        latestSnapshot = snapshot

        guard let processIdentifier, !blockedForProcess else { return }
        switch state {
        case .attached:
            // The main-world bridge receives subsequent token updates from
            // Codex directly. Reinstalling it for every JSONL poll would
            // create duplicate subscriptions and increase renderer risk.
            guard !didProjectInitialSnapshot, snapshot != nil else { return }
            launch(snapshot: snapshot)
        case .unavailable:
            transition(to: .attaching(processIdentifier: processIdentifier))
            launch(snapshot: snapshot)
        case .idle, .attaching:
            break
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
        processIdentifier = nil
        latestSnapshot = nil
        didProjectInitialSnapshot = false
        blockedForProcess = false
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
        let snapshotJSON = Self.snapshotJSON(snapshot)
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
        projectedSnapshot: CodexCacheHitSnapshot?
    ) {
        guard generation == self.generation,
              self.processIdentifier == processIdentifier else {
            return
        }
        operation = nil
        if projectedSnapshot != nil {
            didProjectInitialSnapshot = true
        }
        transition(to: .attached(processIdentifier: processIdentifier))
        onVisibleThreadID?(visibleThreadID)

        if projectedSnapshot == nil,
           let latestSnapshot,
           latestSnapshot != projectedSnapshot,
           !didProjectInitialSnapshot {
            launch(snapshot: latestSnapshot)
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
    }

    private func cancelOperation() {
        generation += 1
        operation?.cancel()
        operation = nil
    }

    private func transition(to nextState: CodexRendererLiveBridgeState) {
        guard state != nextState else { return }
        state = nextState
        onStateChange?(nextState)
    }

    private static func snapshotJSON(_ snapshot: CodexCacheHitSnapshot?) -> String? {
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
            "cacheHitRatePercent": cacheHitRatePercent
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
