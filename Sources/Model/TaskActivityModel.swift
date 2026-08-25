import Foundation

enum CodexTaskActivityKind: String, Codable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case turnActivity = "TurnActivity"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
}

struct CodexTaskActivityEvent: Codable, Equatable, Sendable {
    let kind: CodexTaskActivityKind
    let sessionID: String
    let taskID: String?
    let occurredAt: TimeInterval

    init(
        kind: CodexTaskActivityKind,
        sessionID: String,
        taskID: String? = nil,
        occurredAt: TimeInterval
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.taskID = taskID
        self.occurredAt = occurredAt
    }
}

struct CodexTaskActivityState: Equatable {
    private(set) var completedCount = 0
    private var completedTaskIDs: Set<String> = []
    private var activeTaskBySession: [String: String] = [:]
    private var externalActiveSessionIDs: Set<String> = []
    private var suppressedExternalSessionIDs: Set<String> = []
    private var terminalSessionIDs: Set<String> = []
    private var fallbackSequence = 0

    // A Codex session occupies one visible in-progress slot even when it
    // submits several turns before the session ends.
    var inProgressCount: Int {
        Set(activeTaskBySession.keys)
            .union(externalActiveSessionIDs)
            .count
    }
    // Keep the small x/y indicator present at 0/0 so the activity bridge is
    // visibly available even before the first Codex event arrives.
    var isVisible: Bool { true }

    mutating func apply(_ event: CodexTaskActivityEvent) {
        let sessionID = event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return }

        switch event.kind {
        case .userPromptSubmit:
            let wasActive = activeTaskBySession[sessionID] != nil
                || externalActiveSessionIDs.contains(sessionID)
            suppressedExternalSessionIDs.remove(sessionID)
            terminalSessionIDs.remove(sessionID)
            externalActiveSessionIDs.remove(sessionID)
            // A prompt after a session has ended starts a fresh x/y group.
            // This also applies while another session is still active, so
            // 1/1 becomes 0/2 when the finished conversation resumes.
            if !wasActive {
                beginTaskIfNeeded()
            }
            let taskID = taskID(for: event, sessionID: sessionID)
            // Hooks can deliver one event per turn. Keep one active entry per
            // session so repeated prompts cannot inflate the visible count.
            activeTaskBySession[sessionID] = taskID

        case .turnActivity:
            // Recover a turn when CodexIsland starts after the prompt was
            // submitted, or when a newer Codex build skips that first event.
            guard !terminalSessionIDs.contains(sessionID) else { return }
            suppressedExternalSessionIDs.remove(sessionID)
            guard activeTaskBySession[sessionID] == nil else { return }
            let wasExternallyActive = externalActiveSessionIDs.remove(sessionID) != nil
            if !wasExternallyActive {
                beginTaskIfNeeded()
            }
            let taskID = taskID(for: event, sessionID: sessionID)
            activeTaskBySession[sessionID] = taskID

        case .stop:
            completeTask(sessionID: sessionID)

        case .sessionEnd:
            // Some Codex versions deliver SessionEnd without Stop. Treat the
            // first terminal event as completion; duplicate terminal events
            // stay harmless because the task mapping is removed below.
            completeTask(sessionID: sessionID)
        }
    }

    mutating func reconcileExternalSessions(
        _ sessionIDs: Set<String>,
        completedSessionIDs: Set<String> = []
    ) {
        // The session bridge observes Codex's task_complete event directly.
        // Complete sessions before replacing the external active set so an
        // externally recovered task can still be counted exactly once.
        for sessionID in completedSessionIDs {
            completeTask(sessionID: sessionID)
        }

        let previouslyActiveExternalSessions = externalActiveSessionIDs
        let reactivatedTerminalSessions = sessionIDs.intersection(terminalSessionIDs)
        let newExternalSessions = sessionIDs
            .subtracting(previouslyActiveExternalSessions)
            .subtracting(terminalSessionIDs)
            .subtracting(Set(activeTaskBySession.keys))

        // Codex can reuse one session file for several conversations/turns.
        // Seeing it active again is the authoritative signal that the old
        // terminal suppression no longer applies.
        for sessionID in sessionIDs {
            terminalSessionIDs.remove(sessionID)
            suppressedExternalSessionIDs.remove(sessionID)
        }

        let candidates = sessionIDs
            .subtracting(suppressedExternalSessionIDs)
            .subtracting(terminalSessionIDs)
        // A completed count belongs to the idle batch. The first active
        // external task after that batch starts the next one even when other
        // sessions are already active.
        if completedCount > 0,
           !newExternalSessions.isEmpty || !reactivatedTerminalSessions.isEmpty {
            resetCompletedBatch()
        }
        externalActiveSessionIDs = candidates
        suppressedExternalSessionIDs.formIntersection(sessionIDs)
    }

    private mutating func beginTaskIfNeeded() {
        guard completedCount > 0 else { return }
        resetCompletedBatch()
    }

    private mutating func resetCompletedBatch() {
        completedCount = 0
        completedTaskIDs.removeAll()
    }

    private mutating func completeTask(sessionID: String) {
        // Stop is scoped to the session. Use the mapped turn when available;
        // an externally recovered session has no turn id, so its session id
        // is the stable de-duplication key instead.
        let mappedTaskID = activeTaskBySession.removeValue(forKey: sessionID)
        let hadExternalTask = externalActiveSessionIDs.remove(sessionID) != nil
        terminalSessionIDs.insert(sessionID)
        suppressedExternalSessionIDs.insert(sessionID)

        guard let taskID = mappedTaskID ?? (hadExternalTask ? sessionID : nil) else { return }
        if completedTaskIDs.insert(taskID).inserted {
            completedCount += 1
        }
    }

    private mutating func taskID(
        for event: CodexTaskActivityEvent,
        sessionID: String
    ) -> String {
        if let taskID = event.taskID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !taskID.isEmpty {
            return taskID
        }
        fallbackSequence += 1
        return "\(sessionID)#\(fallbackSequence)"
    }
}
