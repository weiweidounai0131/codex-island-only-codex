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
            suppressedExternalSessionIDs.remove(sessionID)
            // Once every session in a batch has ended, the next prompt starts
            // a fresh x/y group instead of carrying yesterday's completions.
            if activeTaskBySession.isEmpty, completedCount > 0 {
                completedCount = 0
                completedTaskIDs.removeAll()
            }
            let taskID = taskID(for: event, sessionID: sessionID)
            // Hooks can deliver one event per turn. Keep one active entry per
            // session so repeated prompts cannot inflate the visible count.
            activeTaskBySession[sessionID] = taskID

        case .turnActivity:
            // Recover a turn when CodexIsland starts after the prompt was
            // submitted, or when a newer Codex build skips that first event.
            suppressedExternalSessionIDs.remove(sessionID)
            guard activeTaskBySession[sessionID] == nil else { return }
            if activeTaskBySession.isEmpty, completedCount > 0 {
                completedCount = 0
                completedTaskIDs.removeAll()
            }
            let taskID = taskID(for: event, sessionID: sessionID)
            activeTaskBySession[sessionID] = taskID

        case .stop:
            // Stop is scoped to the session. Using the currently mapped task
            // also handles a turn_id mismatch or a missing turn_id safely.
            let taskID = activeTaskBySession.removeValue(forKey: sessionID)
            externalActiveSessionIDs.remove(sessionID)
            suppressedExternalSessionIDs.insert(sessionID)
            guard let taskID else { return }
            if completedTaskIDs.insert(taskID).inserted {
                completedCount += 1
            }

        case .sessionEnd:
            // A session can end because it was closed or cancelled. Only a
            // Stop event counts as a completed task in the reminder.
            activeTaskBySession.removeValue(forKey: sessionID)
            externalActiveSessionIDs.remove(sessionID)
            suppressedExternalSessionIDs.insert(sessionID)
        }
    }

    mutating func reconcileExternalSessions(_ sessionIDs: Set<String>) {
        externalActiveSessionIDs = sessionIDs.subtracting(suppressedExternalSessionIDs)
        suppressedExternalSessionIDs.formIntersection(sessionIDs)
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
