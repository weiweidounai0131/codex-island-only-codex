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
        // Resuming a completed conversation starts a fresh batch, so its
        // previous completion is cleared even while "other" remains active.
        repeatedSession.apply(.init(kind: .stop, sessionID: "same", taskID: "turn-1", occurredAt: 1))
        repeatedSession.apply(.init(kind: .userPromptSubmit, sessionID: "same", taskID: "turn-2", occurredAt: 2))
        precondition(repeatedSession.completedCount == 0)
        precondition(repeatedSession.inProgressCount == 2)
        repeatedSession.apply(.init(kind: .stop, sessionID: "same", taskID: "turn-2", occurredAt: 3))
        precondition(repeatedSession.completedCount == 1)
        precondition(repeatedSession.inProgressCount == 1)

        // When one conversation is complete and another remains active,
        // continuing the completed conversation starts a fresh batch: 1/1
        // becomes 0/2 immediately.
        var continuedConversation = CodexTaskActivityState()
        continuedConversation.apply(.init(kind: .userPromptSubmit, sessionID: "finished", taskID: "turn-finished-1", occurredAt: 0))
        continuedConversation.apply(.init(kind: .userPromptSubmit, sessionID: "live", taskID: "turn-live", occurredAt: 0))
        continuedConversation.apply(.init(kind: .stop, sessionID: "finished", taskID: "turn-finished-1", occurredAt: 1))
        precondition(continuedConversation.completedCount == 1)
        precondition(continuedConversation.inProgressCount == 1)
        continuedConversation.apply(.init(kind: .userPromptSubmit, sessionID: "finished", taskID: "turn-finished-2", occurredAt: 2))
        precondition(continuedConversation.completedCount == 0)
        precondition(continuedConversation.inProgressCount == 2)

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

        // The completed count can expire without touching a task that is
        // still running; an idle 1/0 state therefore returns to 0/0.
        var expiredCompletion = CodexTaskActivityState()
        expiredCompletion.apply(.init(kind: .userPromptSubmit, sessionID: "expiring", taskID: "turn-expiring", occurredAt: 0))
        expiredCompletion.apply(.init(kind: .stop, sessionID: "expiring", taskID: "turn-expiring", occurredAt: 1))
        expiredCompletion.expireCompletedCount()
        precondition(expiredCompletion.completedCount == 0)
        precondition(expiredCompletion.inProgressCount == 0)

        var expiredWithActiveTask = CodexTaskActivityState()
        expiredWithActiveTask.apply(.init(kind: .userPromptSubmit, sessionID: "done", taskID: "turn-done", occurredAt: 0))
        expiredWithActiveTask.apply(.init(kind: .userPromptSubmit, sessionID: "live", taskID: "turn-live", occurredAt: 0))
        expiredWithActiveTask.apply(.init(kind: .stop, sessionID: "done", taskID: "turn-done", occurredAt: 1))
        expiredWithActiveTask.expireCompletedCount()
        precondition(expiredWithActiveTask.completedCount == 0)
        precondition(expiredWithActiveTask.inProgressCount == 1)

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
        // snapshot is a new task after completion, so it clears x and
        // restores y.
        externalCompletion.reconcileExternalSessions(["external"])
        precondition(externalCompletion.completedCount == 0)
        precondition(externalCompletion.inProgressCount == 1)
        externalCompletion.reconcileExternalSessions(["external", "next-external"])
        precondition(externalCompletion.completedCount == 0)
        precondition(externalCompletion.inProgressCount == 2)

        // Same behavior when another external conversation is still active.
        var externalOverlap = CodexTaskActivityState()
        externalOverlap.reconcileExternalSessions(["finished", "live"])
        externalOverlap.reconcileExternalSessions(
            ["live"],
            completedSessionIDs: ["finished"]
        )
        precondition(externalOverlap.completedCount == 1)
        precondition(externalOverlap.inProgressCount == 1)
        externalOverlap.reconcileExternalSessions(["finished", "live"])
        precondition(externalOverlap.completedCount == 0)
        precondition(externalOverlap.inProgressCount == 2)

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
