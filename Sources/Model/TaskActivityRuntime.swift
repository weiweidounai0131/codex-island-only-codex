import AppKit
import Combine
import Foundation
import Darwin

@MainActor
final class CodexTaskActivityStore: ObservableObject {
    static let shared = CodexTaskActivityStore()

    private static let completedDisplayDurationNanoseconds: UInt64 = 300_000_000_000

    @Published private(set) var state = CodexTaskActivityState()
    private var completionExpiryTask: Task<Void, Never>?

    private init() {}

    func receive(_ event: CodexTaskActivityEvent) {
        let previousCompletedCount = state.completedCount
        let previousInProgressCount = state.inProgressCount
        state.apply(event)
        updateCompletionExpiry(
            previousCompletedCount: previousCompletedCount,
            previousInProgressCount: previousInProgressCount
        )
    }

    func reconcileExternalSessions(
        _ sessionIDs: Set<String>,
        completedSessionIDs: Set<String> = []
    ) {
        let previousCompletedCount = state.completedCount
        let previousInProgressCount = state.inProgressCount
        var nextState = state
        nextState.reconcileExternalSessions(
            sessionIDs,
            completedSessionIDs: completedSessionIDs
        )
        guard nextState != state else { return }
        state = nextState
        updateCompletionExpiry(
            previousCompletedCount: previousCompletedCount,
            previousInProgressCount: previousInProgressCount
        )
    }

    private func updateCompletionExpiry(
        previousCompletedCount: Int,
        previousInProgressCount: Int
    ) {
        // The completion count is a stable summary only after every active
        // conversation has ended. Do not expire an intermediate 1/1 state;
        // start the five-minute window when the state becomes fully idle.
        guard state.completedCount > 0, state.inProgressCount == 0 else {
            completionExpiryTask?.cancel()
            completionExpiryTask = nil
            return
        }

        let enteredIdle = previousInProgressCount > 0 && state.inProgressCount == 0
        guard state.completedCount != previousCompletedCount || enteredIdle else { return }
        completionExpiryTask?.cancel()
        completionExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.completedDisplayDurationNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.expireCompletedCount()
        }
    }

    private func expireCompletedCount() {
        guard state.completedCount > 0 else {
            completionExpiryTask = nil
            return
        }

        state.expireCompletedCount()
        completionExpiryTask = nil
    }
}

private enum CodexTaskActivityPaths {
    static let fileManager = FileManager.default

    static var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var appDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("CodexIsland oc", isDirectory: true)
    }

    static var queueDirectory: URL {
        appDirectory.appendingPathComponent("TaskActivityQueue", isDirectory: true)
    }

    static var helperInstallURL: URL {
        appDirectory
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CodexIslandTaskActivityHook")
    }

    static var hooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }
}

private enum CodexTaskActivitySecurity {
    static func ensureDirectory(_ url: URL, create: Bool) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            guard create else { throw CocoaError(.fileNoSuchFile) }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }

        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    static func isSafeEventFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              info.st_size <= 64 * 1024 else {
            return false
        }
        return true
    }
}

/// Read-only fallback for Codex desktop sessions that were already running
/// before the hook was installed or trusted. It inspects only session file
/// metadata and the final event type; message bodies are never decoded.
private final class CodexSessionActivityBridge {
    private static let maxAge: TimeInterval = 15 * 60
    private static let tailBytes = 128 * 1024

    private struct FileSnapshot {
        let path: String
        let modifiedAt: Date
        let fileSize: UInt64
        let isTerminal: Bool
    }

    private let directoryURL: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.weiweidounai0131.CodexIslandOC.session-activity")
    private var source: DispatchSourceTimer?
    private var lastActiveSessionIDs: Set<String> = []
    private var fileSnapshots: [String: FileSnapshot] = [:]

    var onSessionsChange: ((Set<String>, Set<String>) -> Void)?

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
    }

    func start() {
        guard source == nil else { return }
        scan()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + 1,
            repeating: .seconds(2),
            leeway: .milliseconds(250)
        )
        source.setEventHandler { [weak self] in
            self?.scan()
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func scan() {
        var sessionIDs: Set<String> = []
        var completedSessionIDs: Set<String> = []
        var seenSessionIDs: Set<String> = []
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            publishIfChanged(sessionIDs, completedSessionIDs: completedSessionIDs)
            return
        }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let sessionID = sessionID(from: url),
                  let values = try? url.resourceValues(
                      forKeys: [
                          .isRegularFileKey,
                          .contentModificationDateKey,
                          .fileSizeKey
                      ]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  Date().timeIntervalSince(modifiedAt) <= Self.maxAge else {
                continue
            }

            seenSessionIDs.insert(sessionID)
            let fileSize = UInt64(max(0, values.fileSize ?? 0))
            let terminal: Bool
            if let snapshot = fileSnapshots[sessionID],
               snapshot.path == url.path,
               snapshot.modifiedAt == modifiedAt,
               snapshot.fileSize == fileSize {
                terminal = snapshot.isTerminal
            } else {
                terminal = isTerminal(url)
                fileSnapshots[sessionID] = FileSnapshot(
                    path: url.path,
                    modifiedAt: modifiedAt,
                    fileSize: fileSize,
                    isTerminal: terminal
                )
            }

            if terminal {
                // Only count a terminal file when this bridge previously saw
                // the same session as active. This prevents old completed
                // sessions from becoming false completions after app launch.
                if lastActiveSessionIDs.contains(sessionID) {
                    completedSessionIDs.insert(sessionID)
                }
                continue
            }
            sessionIDs.insert(sessionID)
        }

        fileSnapshots = fileSnapshots.filter { seenSessionIDs.contains($0.key) }
        publishIfChanged(sessionIDs, completedSessionIDs: completedSessionIDs)
    }

    private func publishIfChanged(
        _ sessionIDs: Set<String>,
        completedSessionIDs: Set<String>
    ) {
        guard sessionIDs != lastActiveSessionIDs || !completedSessionIDs.isEmpty else { return }
        lastActiveSessionIDs = sessionIDs
        let callback = onSessionsChange
        DispatchQueue.main.async {
            callback?(sessionIDs, completedSessionIDs)
        }
    }

    private func sessionID(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let candidate = String(stem.suffix(36))
        guard UUID(uuidString: candidate) != nil else { return nil }
        return candidate
    }

    private func isTerminal(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return false }
        let offset = fileSize > UInt64(Self.tailBytes)
            ? fileSize - UInt64(Self.tailBytes)
            : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }

        var latestLifecycleEvent: String?
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData)
                      as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }
            if ["task_started", "task_complete", "turn_aborted"].contains(eventType) {
                latestLifecycleEvent = eventType
                break
            }
        }

        return latestLifecycleEvent == "task_complete"
            || latestLifecycleEvent == "turn_aborted"
    }
}

private final class CodexTaskActivityQueueBridge {
    let directoryURL: URL
    var onEvent: ((CodexTaskActivityEvent) -> Void)?

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.weiweidounai0131.CodexIslandOC.task-activity")
    private var directoryDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func start() {
        guard source == nil else { return }
        do {
            try CodexTaskActivitySecurity.ensureDirectory(directoryURL, create: true)
        } catch {
            return
        }

        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        directoryDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryDescriptor >= 0 else { return }
            close(self.directoryDescriptor)
            self.directoryDescriptor = -1
        }
        self.source = source
        source.resume()
        drain()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let eventFiles = files
            .filter { $0.lastPathComponent.hasPrefix("event-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in eventFiles {
            guard CodexTaskActivitySecurity.isSafeEventFile(file) else {
                try? fileManager.removeItem(at: file)
                continue
            }

            if let data = try? Data(contentsOf: file),
               let event = try? JSONDecoder().decode(CodexTaskActivityEvent.self, from: data) {
                onEvent?(event)
            }
            try? fileManager.removeItem(at: file)
        }
    }
}

@MainActor
final class CodexTaskActivityRuntime {
    private let store = CodexTaskActivityStore.shared
    private let bridge: CodexTaskActivityQueueBridge
    private let sessionBridge: CodexSessionActivityBridge
    private let installer: CodexTaskActivityHookInstaller
    private var installTask: Task<Void, Never>?

    init() {
        let queueDirectory = CodexTaskActivityPaths.queueDirectory
        bridge = CodexTaskActivityQueueBridge(directoryURL: queueDirectory)
        sessionBridge = CodexSessionActivityBridge()
        installer = CodexTaskActivityHookInstaller(queueDirectory: queueDirectory)
        bridge.onEvent = { event in
            Task { @MainActor in
                CodexTaskActivityStore.shared.receive(event)
            }
        }
        sessionBridge.onSessionsChange = { sessionIDs, completedSessionIDs in
            Task { @MainActor in
                CodexTaskActivityStore.shared.reconcileExternalSessions(
                    sessionIDs,
                    completedSessionIDs: completedSessionIDs
                )
            }
        }
    }

    func start() {
        bridge.start()
        sessionBridge.start()
        let installer = self.installer
        installTask = Task.detached(priority: .utility) {
            try? installer.install()
        }
    }

    func stop() {
        installTask?.cancel()
        installTask = nil
        bridge.stop()
        sessionBridge.stop()
        _ = store
    }
}

private final class CodexTaskActivityHookInstaller: @unchecked Sendable {
    private static let marker = "CodexIslandTaskActivityHook"

    let queueDirectory: URL

    init(queueDirectory: URL) {
        self.queueDirectory = queueDirectory
    }

    func install() throws {
        let fileManager = FileManager.default
        try CodexTaskActivitySecurity.ensureDirectory(queueDirectory, create: true)

        let bundledHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(Self.marker)
        guard fileManager.isExecutableFile(atPath: bundledHelper.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let helperDirectory = queueDirectory.deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true)
        try fileManager.createDirectory(
            at: helperDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try? fileManager.removeItem(at: CodexTaskActivityPaths.helperInstallURL)
        try fileManager.copyItem(at: bundledHelper, to: CodexTaskActivityPaths.helperInstallURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: CodexTaskActivityPaths.helperInstallURL.path
        )

        let hooksURL = CodexTaskActivityPaths.hooksURL
        let codexDirectory = hooksURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: codexDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        let hooksFileExists = fileManager.fileExists(atPath: hooksURL.path)
        var root: [String: Any]
        if hooksFileExists {
            guard let data = try? Data(contentsOf: hooksURL),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root = decoded
        } else {
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = "\(shellQuote(CodexTaskActivityPaths.helperInstallURL.path)) --queue \(shellQuote(queueDirectory.path))"
        // UserPromptSubmit starts a visible task. The additional lifecycle
        // hooks recover a turn when CodexIsland starts after the prompt was
        // submitted, or when the updated Codex app skips that first event.
        // SessionStart covers a new conversation before its first prompt.
        let eventNames = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
            "Stop",
            "SessionEnd"
        ]
        for eventName in eventNames {
            var entries = hooks[eventName] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                let commands = (entry["hooks"] as? [[String: Any]]) ?? []
                return commands.contains { command in
                    (command["command"] as? String)?.contains(Self.marker) == true
                }
            }
            entries.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": eventName == "SessionEnd" ? 1 : 2,
                    "async": true
                ]]
            ])
            hooks[eventName] = entries
        }
        root["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        let temporaryURL = hooksURL
            .deletingLastPathComponent()
            .appendingPathComponent(".hooks.json.codexisland-\(UUID().uuidString)")
        try data.write(to: temporaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporaryURL.path
        )

        if fileManager.fileExists(atPath: hooksURL.path) {
            _ = try fileManager.replaceItemAt(hooksURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: hooksURL)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
