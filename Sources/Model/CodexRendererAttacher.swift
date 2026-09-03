import Foundation

enum CodexRendererAttachFailure: Equatable {
    case wrongProcessTarget
    case noApprovedStockEndpoint
}

enum CodexRendererAttachState: Equatable {
    case idle
    case waitingForCodex
    case attaching(processIdentifier: Int32)
    case attached(processIdentifier: Int32)
    case unavailable(CodexRendererAttachFailure)
}

/// M0's fail-closed renderer boundary.
///
/// No safe stock endpoint was proven during the compatibility probe. This
/// object intentionally contains no launcher, CDP client, AppleScript, remote
/// debugging, app-server, or bundle-patching path. The `.attached` state is a
/// contract state for a later, separately approved implementation; M0 never
/// reaches it.
final class CodexRendererAttacher {
    private(set) var state: CodexRendererAttachState = .idle
    var onStateChange: ((CodexRendererAttachState) -> Void)?

    func waitForCodex() {
        transition(to: .waitingForCodex)
    }

    func attach(to process: CodexProcessIdentity) {
        guard process.bundleIdentifier == CodexProcessWatcherCore.targetBundleIdentifier,
              process.processIdentifier > 0 else {
            transition(to: .unavailable(.wrongProcessTarget))
            return
        }

        transition(to: .attaching(processIdentifier: process.processIdentifier))

        // Fail closed. There is no approved stock endpoint to execute
        // renderer JavaScript without changing or taking over Codex.
        transition(to: .unavailable(.noApprovedStockEndpoint))
    }

    func stop() {
        transition(to: .idle)
    }

    private func transition(to nextState: CodexRendererAttachState) {
        guard state != nextState else { return }
        state = nextState
        onStateChange?(nextState)
    }
}

/// Small lifecycle container owned by CodexIsland oc. The existing
/// `CODEXISLAND_DEBUG=1` environment gate is the only way M0 is enabled;
/// normal/release launches remain inert.
final class CodexM0RuntimeController {
    private let enabled: Bool
    private let watcher: CodexProcessWatching
    let attacher: CodexRendererAttacher
    private var started = false

    init(
        enabled: Bool = AppEnvironment.isDebug,
        watcher: CodexProcessWatching? = nil,
        attacher: CodexRendererAttacher = CodexRendererAttacher()
    ) {
        self.enabled = enabled
        self.watcher = watcher ?? CodexProcessWatcher()
        self.attacher = attacher
    }

    var state: CodexRendererAttachState {
        attacher.state
    }

    func start() {
        guard enabled, !started else { return }
        started = true
        watcher.onStateChange = { [weak self] nextState in
            self?.handle(nextState)
        }
        attacher.waitForCodex()
        watcher.start()
    }

    func stop() {
        guard started || state != .idle else { return }
        started = false
        watcher.onStateChange = nil
        watcher.stop()
        attacher.stop()
    }

    deinit {
        watcher.onStateChange = nil
        watcher.stop()
        attacher.stop()
    }

    private func handle(_ nextState: CodexProcessWatcherState) {
        switch nextState {
        case .stopped:
            attacher.stop()
        case .waitingForCodex:
            attacher.waitForCodex()
        case .running(let processIdentifier):
            attacher.attach(
                to: CodexProcessIdentity(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: CodexProcessWatcherCore.targetBundleIdentifier
                )
            )
        }
    }
}
