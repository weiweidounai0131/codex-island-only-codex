import Foundation

@main
struct TaskActivityTests {
    static func main() {
        var state = CodexTaskActivityState()

        for id in ["a", "b", "c"] {
            state.apply(.init(kind: .userPromptSubmit, sessionID: id, taskID: "turn-\(id)", occurredAt: 0))
        }
        precondition(state.completedCount == 0)
        precondition(state.inProgressCount == 3)

        state.apply(.init(kind: .stop, sessionID: "b", taskID: "turn-b", occurredAt: 1))
        precondition(state.completedCount == 1)
        precondition(state.inProgressCount == 2)

        // Hook delivery can be retried; a duplicate Stop must be harmless.
        state.apply(.init(kind: .stop, sessionID: "b", taskID: "turn-b", occurredAt: 2))
        precondition(state.completedCount == 1)
        precondition(state.inProgressCount == 2)

        state.apply(.init(kind: .sessionEnd, sessionID: "a", taskID: "turn-a", occurredAt: 3))
        precondition(state.completedCount == 2)
        precondition(state.inProgressCount == 1)

        state.apply(.init(kind: .stop, sessionID: "c", taskID: "turn-c", occurredAt: 4))
        precondition(state.completedCount == 3)
        precondition(state.inProgressCount == 0)

        // A prompt after the old batch starts a clean counter.
        state.apply(.init(kind: .userPromptSubmit, sessionID: "d", taskID: "turn-d", occurredAt: 5))
        precondition(state.completedCount == 0)
        precondition(state.inProgressCount == 1)
        precondition(state.isVisible)

        var empty = CodexTaskActivityState()
        empty.apply(.init(kind: .sessionEnd, sessionID: "missing", taskID: nil, occurredAt: 0))
        precondition(empty.isVisible)

        // A tool or permission event can be the first event observed after
        // the app starts while a Codex turn is already running.
        var recovered = CodexTaskActivityState()
        recovered.apply(.init(kind: .turnActivity, sessionID: "tool", taskID: "turn-tool", occurredAt: 0))
        precondition(recovered.inProgressCount == 1)

        var repeatedSession = CodexTaskActivityState()
        repeatedSession.apply(.init(kind: .userPromptSubmit, sessionID: "same", taskID: "turn-1", occurredAt: 0))
        repeatedSession.apply(.init(kind: .userPromptSubmit, sessionID: "other", taskID: "turn-other", occurredAt: 0))
        precondition(repeatedSession.inProgressCount == 2)
        // A second turn in the same conversation must not create a second
        // visible in-progress task.
        repeatedSession.apply(.init(kind: .stop, sessionID: "same", taskID: "turn-1", occurredAt: 1))
        repeatedSession.apply(.init(kind: .userPromptSubmit, sessionID: "same", taskID: "turn-2", occurredAt: 2))
        precondition(repeatedSession.completedCount == 1)
        precondition(repeatedSession.inProgressCount == 2)
        repeatedSession.apply(.init(kind: .stop, sessionID: "same", taskID: "turn-2", occurredAt: 3))
        precondition(repeatedSession.completedCount == 2)
        precondition(repeatedSession.inProgressCount == 1)

        // Repeated prompts in one still-running session remain one slot, and
        // closing that session removes the slot completely.
        var duplicatePrompt = CodexTaskActivityState()
        duplicatePrompt.apply(.init(kind: .userPromptSubmit, sessionID: "live", taskID: "turn-1", occurredAt: 0))
        duplicatePrompt.apply(.init(kind: .userPromptSubmit, sessionID: "live", taskID: "turn-2", occurredAt: 1))
        duplicatePrompt.apply(.init(kind: .userPromptSubmit, sessionID: "live", taskID: "turn-3", occurredAt: 2))
        precondition(duplicatePrompt.inProgressCount == 1)
        duplicatePrompt.apply(.init(kind: .sessionEnd, sessionID: "live", taskID: "turn-3", occurredAt: 3))
        precondition(duplicatePrompt.completedCount == 1)
        precondition(duplicatePrompt.inProgressCount == 0)

        // A Stop for an already-removed session must not resurrect or count it.
        duplicatePrompt.apply(.init(kind: .stop, sessionID: "live", taskID: "turn-3", occurredAt: 4))
        precondition(duplicatePrompt.completedCount == 1)
        precondition(duplicatePrompt.inProgressCount == 0)

        // Completion remains visible while the app is idle. A late activity
        // event from the finished session must not erase it or reopen y.
        var stickyCompletion = CodexTaskActivityState()
        stickyCompletion.apply(.init(kind: .userPromptSubmit, sessionID: "solo", taskID: "turn-solo", occurredAt: 0))
        precondition(stickyCompletion.completedCount == 0)
        precondition(stickyCompletion.inProgressCount == 1)
        stickyCompletion.apply(.init(kind: .sessionEnd, sessionID: "solo", taskID: "turn-solo", occurredAt: 1))
        precondition(stickyCompletion.completedCount == 1)
        precondition(stickyCompletion.inProgressCount == 0)
        stickyCompletion.apply(.init(kind: .turnActivity, sessionID: "solo", taskID: "turn-solo", occurredAt: 2))
        precondition(stickyCompletion.completedCount == 1)
        precondition(stickyCompletion.inProgressCount == 0)

        // The next new conversation changes y from 0 to 1 and starts a new
        // batch, clearing the previous x value at that moment.
        stickyCompletion.apply(.init(kind: .userPromptSubmit, sessionID: "next", taskID: "turn-next", occurredAt: 3))
        precondition(stickyCompletion.completedCount == 0)
        precondition(stickyCompletion.inProgressCount == 1)
        stickyCompletion.apply(.init(kind: .stop, sessionID: "next", taskID: "turn-next", occurredAt: 4))
        precondition(stickyCompletion.completedCount == 1)
        precondition(stickyCompletion.inProgressCount == 0)

        // The session-file fallback must turn an active-to-terminal
        // transition into the same completion count as a Hook event.
        var externalCompletion = CodexTaskActivityState()
        externalCompletion.reconcileExternalSessions(["external"])
        precondition(externalCompletion.completedCount == 0)
        precondition(externalCompletion.inProgressCount == 1)
        externalCompletion.reconcileExternalSessions(["external", "new-external"])
        precondition(externalCompletion.completedCount == 0)
        precondition(externalCompletion.inProgressCount == 2)
        externalCompletion.reconcileExternalSessions(
            [],
            completedSessionIDs: ["external"]
        )
        precondition(externalCompletion.completedCount == 1)
        precondition(externalCompletion.inProgressCount == 0)
        externalCompletion.reconcileExternalSessions(
            [],
            completedSessionIDs: ["external"]
        )
        precondition(externalCompletion.completedCount == 1)
        precondition(externalCompletion.inProgressCount == 0)
        // A later task can reuse the same Codex session file. Its active
        // snapshot restores y without clearing x because it is the same
        // conversation, not a new session.
        externalCompletion.reconcileExternalSessions(["external"])
        precondition(externalCompletion.completedCount == 1)
        precondition(externalCompletion.inProgressCount == 1)
        externalCompletion.reconcileExternalSessions(["external", "next-external"])
        precondition(externalCompletion.completedCount == 0)
        precondition(externalCompletion.inProgressCount == 2)

        // Stop and SessionEnd can arrive in either order, but one task counts
        // only once.
        var terminalOrder = CodexTaskActivityState()
        terminalOrder.apply(.init(kind: .userPromptSubmit, sessionID: "ordered", taskID: "turn-ordered", occurredAt: 0))
        terminalOrder.apply(.init(kind: .stop, sessionID: "ordered", taskID: "turn-ordered", occurredAt: 1))
        terminalOrder.apply(.init(kind: .sessionEnd, sessionID: "ordered", taskID: "turn-ordered", occurredAt: 2))
        precondition(terminalOrder.completedCount == 1)
        precondition(terminalOrder.inProgressCount == 0)

        print("task activity tests passed")
    }
}
