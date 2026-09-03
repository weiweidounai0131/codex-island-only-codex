import AppKit
import Foundation

/// The only process identity that M0 is allowed to observe.
struct CodexProcessIdentity: Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String
}

enum CodexProcessWatcherState: Equatable {
    case stopped
    case waitingForCodex
    case running(processIdentifier: Int32)
}

/// Pure process filtering and de-duplication. Keeping this separate from
/// NSWorkspace makes the M0 lifecycle rules testable without touching the
/// user's running applications.
struct CodexProcessWatcherCore: Equatable {
    static let targetBundleIdentifier = "com.openai.codex"

    private(set) var runningProcessIdentifiers: Set<Int32> = []

    var state: CodexProcessWatcherState {
        guard let processIdentifier = runningProcessIdentifiers.min() else {
            return .waitingForCodex
        }
        return .running(processIdentifier: processIdentifier)
    }

    mutating func bootstrap(_ applications: [CodexProcessIdentity]) -> Bool {
        let next = Set(
            applications
                .filter(isTarget)
                .map(\.processIdentifier)
        )
        return replace(with: next)
    }

    mutating func handleLaunch(_ application: CodexProcessIdentity) -> Bool {
        guard isTarget(application) else { return false }
        return runningProcessIdentifiers.insert(application.processIdentifier).inserted
    }

    mutating func handleTerminate(_ application: CodexProcessIdentity) -> Bool {
        guard isTarget(application) else { return false }
        return runningProcessIdentifiers.remove(application.processIdentifier) != nil
    }

    mutating func reset() -> Bool {
        replace(with: [])
    }

    private func isTarget(_ application: CodexProcessIdentity) -> Bool {
        application.bundleIdentifier == Self.targetBundleIdentifier
            && application.processIdentifier > 0
    }

    private mutating func replace(with processIdentifiers: Set<Int32>) -> Bool {
        guard processIdentifiers != runningProcessIdentifiers else { return false }
        runningProcessIdentifiers = processIdentifiers
        return true
    }
}

protocol CodexProcessWatching: AnyObject {
    var onStateChange: ((CodexProcessWatcherState) -> Void)? { get set }

    func start()
    func stop()
}

/// Observes the stock Codex application only. It never launches Codex and it
/// does not inspect or control any child process, socket, app-server, or
/// renderer. A restart naturally arrives as terminate followed by launch.
final class CodexProcessWatcher: CodexProcessWatching {
    static let targetBundleIdentifier = CodexProcessWatcherCore.targetBundleIdentifier

    var onStateChange: ((CodexProcessWatcherState) -> Void)?

    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let runningApplicationsProvider: () -> [NSRunningApplication]
    private var observerTokens: [NSObjectProtocol] = []
    private var core = CodexProcessWatcherCore()
    private var started = false

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        self.notificationCenter = workspace.notificationCenter
        self.runningApplicationsProvider = { workspace.runningApplications }
    }

    func start() {
        guard !started else { return }
        started = true

        observerTokens = [
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleLaunch(notification)
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleTerminate(notification)
            }
        ]

        let applications = runningApplicationsProvider().compactMap(Self.identity)
        _ = core.bootstrap(applications)
        publish(core.state)
    }

    func stop() {
        guard started || !observerTokens.isEmpty || !core.runningProcessIdentifiers.isEmpty else {
            return
        }
        started = false
        removeObservers()
        _ = core.reset()
        publish(.stopped)
    }

    deinit {
        removeObservers()
    }

    private var state: CodexProcessWatcherState {
        core.state
    }

    private func handleLaunch(_ notification: Notification) {
        guard let identity = Self.identity(from: notification) else { return }
        guard core.handleLaunch(identity) else { return }
        publish(core.state)
    }

    private func handleTerminate(_ notification: Notification) {
        guard let identity = Self.identity(from: notification) else { return }
        guard core.handleTerminate(identity) else { return }
        publish(core.state)
    }

    private func publish(_ nextState: CodexProcessWatcherState) {
        onStateChange?(nextState)
    }

    private func removeObservers() {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private static func identity(from notification: Notification) -> CodexProcessIdentity? {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else {
            return nil
        }
        return identity(from: application)
    }

    private static func identity(from application: NSRunningApplication) -> CodexProcessIdentity? {
        guard let bundleIdentifier = application.bundleIdentifier else { return nil }
        return CodexProcessIdentity(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }
}
