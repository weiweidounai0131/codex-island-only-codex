import Foundation

@main
struct CodexLaunchTests {
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
        let arguments = CodexRendererLaunch.arguments(for: 43123)
        expect(
            arguments == ["--remote-debugging-port=43123"],
            "launches the official executable with the explicit Renderer argument"
        )
        expect(
            CodexInspectorDiscovery.rendererPort(in: "ChatGPT \(arguments.joined(separator: " "))\n") == 43123,
            "the launch argument is discoverable from ps output"
        )

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("Codex launch tests passed")
    }
}
