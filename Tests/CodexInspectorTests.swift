import Foundation

@main
struct CodexInspectorTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func main() {
        expect(
            CodexInspectorDiscovery.rendererPort(
                in: "ChatGPT --remote-debugging-port=43124"
            ) == 43124,
            "accepts an explicit Renderer debugging port"
        )
        expect(
            CodexInspectorDiscovery.rendererPort(
                in: "ChatGPT --remote-debugging-port=43124\n"
            ) == 43124,
            "accepts an explicit Renderer debugging port from ps output"
        )
        expect(
            CodexInspectorDiscovery.rendererPort(
                in: "ChatGPT --inspect=127.0.0.1:43123"
            ) == nil,
            "ignores a Node Inspector-only launch"
        )
        expect(
            CodexInspectorDiscovery.rendererPort(
                in: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ) == nil,
            "rejects a normal stock launch without Renderer debugging"
        )
        expect(
            CodexInspectorDiscovery.rendererPort(
                in: "ChatGPT --remote-debugging-port=0"
            ) == nil,
            "rejects an invalid Renderer debugging port"
        )
        expect(
            CodexInspectorDiscovery.rendererPageScore(
                url: "app://-/index.html"
            ) == 100,
            "prefers the main Codex renderer page"
        )
        expect(
            CodexInspectorDiscovery.rendererPageScore(
                url: "app://-/index.html?initialRoute=%2Favatar-overlay"
            ) == nil,
            "ignores auxiliary initialRoute pages"
        )
        expect(
            CodexInspectorDiscovery.rendererPageScore(
                url: "app://-/detached-window.html?initialRoute=%2Fdetached-window"
            ) == nil,
            "ignores detached Codex windows"
        )
        expect(
            CodexInspectorDiscovery.rendererPageURLs(in: [
                [
                    "type": "page",
                    "url": "app://-/index.html?initialRoute=%2Favatar-overlay",
                    "webSocketDebuggerUrl": "ws://127.0.0.1:43123/devtools/page/overlay"
                ],
                [
                    "type": "page",
                    "url": "app://-/index.html",
                    "webSocketDebuggerUrl": "ws://127.0.0.1:43123/devtools/page/main"
                ]
            ]) == ["app://-/index.html"],
            "orders the main page before auxiliary pages"
        )
        expect(
            CodexRendererInspectorAttachment.snapshotBootstrapStatement(
                "{\"threadId\":\"thread-a\"}"
            ) == "api.setSnapshot({\"threadId\":\"thread-a\"});",
            "passes the bootstrap snapshot as a JSON object"
        )
        expect(
            CodexRendererInspectorAttachment.snapshotBootstrapStatement(nil) == nil,
            "omits the bootstrap snapshot when no local snapshot exists"
        )

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("Inspector safety tests passed")
    }
}
