import Foundation

@main
struct CodexCacheHitTests {
    private static var failures = 0

    private static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    private static func jsonLine(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexisland-ch-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("rollout-test.jsonl")
        let lines = [
            jsonLine([
                "type": "session_meta",
                "payload": ["id": "thread-a"]
            ]),
            jsonLine([
                "type": "turn_context",
                "timestamp": "2026-09-03T10:00:00.000Z",
                "payload": ["turn_id": "turn-a", "model": "gpt-5.5"]
            ]),
            jsonLine([
                "type": "event_msg",
                "timestamp": "2026-09-03T10:00:01.000Z",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 100_000,
                            "cached_input_tokens": 75_000,
                            "output_tokens": 4_100,
                            "reasoning_output_tokens": 2_300,
                            "total_tokens": 106_400
                        ],
                        "total_token_usage": [
                            "input_tokens": 500_000,
                            "cached_input_tokens": 450_000,
                            "cache_write_input_tokens": 1_200,
                            "output_tokens": 12_100,
                            "reasoning_output_tokens": 6_300,
                            "total_tokens": 518_400
                        ],
                        "model_context_window": 272_000
                    ]
                ]
            ]),
            jsonLine([
                "type": "turn_context",
                "timestamp": "2026-09-03T10:01:00.000Z",
                "payload": ["turn_id": "turn-b", "model": "gpt-5.5"]
            ]),
            jsonLine([
                "type": "event_msg",
                "timestamp": "2026-09-03T10:01:01.000Z",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 20_000,
                            "cached_input_tokens": 10_000,
                            "output_tokens": 1_000,
                            "total_tokens": 21_000
                        ]
                    ]
                ]
            ])
        ]
        try! (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let reader = CodexCacheHitReader(directoryURL: root, lookbackDays: 1)
        let snapshots = reader.read()
        expect(snapshots.count == 2, "reads one snapshot per turn")

        let first = snapshots.first { $0.turnID == "turn-a" }
        expect(first?.sessionID == "thread-a", "keeps the session id")
        expect(first?.model == "gpt-5.5", "keeps the active model")
        expect(first?.inputTokens == 500_000, "keeps cumulative input tokens")
        expect(first?.cachedInputTokens == 450_000, "keeps cumulative cached input tokens")
        expect(first?.cacheWriteInputTokens == 1_200, "keeps cumulative cache writes")
        expect(first?.lastTotalTokens == 106_400, "keeps latest context tokens")
        expect(first?.lastInputTokens == 100_000, "keeps latest input tokens for CH")
        expect(first?.lastCachedInputTokens == 75_000, "keeps latest cached input tokens for CH")
        expect(first?.cacheHitRatePercent == 75, "computes CH from the latest request")
        expect(first?.modelContextWindow == 272_000, "keeps model context window")
        expect(first?.totalTokens == 518_400, "keeps cumulative total tokens")

        let missingLatest = CodexCacheHitSnapshot(
            sessionID: "session-a",
            turnID: "turn-missing-last",
            timestamp: Date(),
            model: "gpt-5.6",
            inputTokens: 500_000,
            cachedInputTokens: 450_000,
            outputTokens: 12_100,
            reasoningOutputTokens: 6_300,
            totalTokens: 518_400,
            modelContextWindow: 1_000_000
        )
        expect(missingLatest.cacheHitRatePercent == nil, "does not use cumulative totals as CH")

        let missingTurn = root.appendingPathComponent("rollout-no-turn.jsonl")
        let missingTurnLine = jsonLine([
            "type": "session_meta",
            "payload": ["id": "thread-without-turn"]
        ]) + "\n" + jsonLine([
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": ["last_token_usage": ["input_tokens": 100, "cached_input_tokens": 90]]
            ]
        ]) + "\n"
        try! missingTurnLine.write(to: missingTurn, atomically: true, encoding: .utf8)
        let withMissingTurn = CodexCacheHitReader(directoryURL: root, lookbackDays: 1).read()
        expect(
            withMissingTurn.allSatisfy { $0.sessionID != "thread-without-turn" },
            "drops usage without a stable turn id"
        )

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("cache hit tests passed")
    }
}
