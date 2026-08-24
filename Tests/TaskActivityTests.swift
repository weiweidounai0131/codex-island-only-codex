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
        precondition(state.completedCount == 1)
        precondition(state.inProgressCount == 1)

        state.apply(.init(kind: .stop, sessionID: "c", taskID: "turn-c", occurredAt: 4))
        precondition(state.completedCount == 2)
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
        precondition(duplicatePrompt.completedCount == 0)
        precondition(duplicatePrompt.inProgressCount == 0)

        // A Stop for an already-removed session must not resurrect or count it.
        duplicatePrompt.apply(.init(kind: .stop, sessionID: "live", taskID: "turn-3", occurredAt: 4))
        precondition(duplicatePrompt.completedCount == 0)
        precondition(duplicatePrompt.inProgressCount == 0)

        print("task activity tests passed")
    }
}
