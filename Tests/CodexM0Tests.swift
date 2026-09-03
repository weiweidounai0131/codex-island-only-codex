import Foundation

private final class FakeCodexProcessWatcher: CodexProcessWatching {
    var onStateChange: ((CodexProcessWatcherState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ state: CodexProcessWatcherState) {
        onStateChange?(state)
    }
}

@main
struct CodexM0Tests {
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
        let target = CodexProcessIdentity(
            processIdentifier: 42,
            bundleIdentifier: CodexProcessWatcherCore.targetBundleIdentifier
        )
        let wrongBundle = CodexProcessIdentity(
            processIdentifier: 43,
            bundleIdentifier: "com.example.not-codex"
        )

        var core = CodexProcessWatcherCore()
        expect(core.bootstrap([wrongBundle, target]), "startup discovers exact Codex bundle")
        expect(core.state == .running(processIdentifier: 42), "startup publishes running Codex")
        expect(!core.handleLaunch(target), "duplicate launch is idempotent")
        expect(!core.handleLaunch(wrongBundle), "wrong bundle is ignored")
        expect(!core.handleTerminate(wrongBundle), "wrong bundle terminate is ignored")
        expect(core.handleTerminate(target), "Codex terminate is observed")
        expect(core.state == .waitingForCodex, "terminate returns to waiting")
        expect(core.handleLaunch(target), "launch after terminate is a restart")
        expect(core.state == .running(processIdentifier: 42), "restart returns to running")
        expect(core.handleTerminate(target), "restart terminate is observed")
        expect(!core.handleTerminate(target), "duplicate terminate is idempotent")
        expect(core.handleLaunch(target), "reset fixture restores a running Codex")
        expect(core.reset(), "reset clears the process state")
        expect(!core.reset(), "duplicate reset is idempotent")

        let attacher = CodexRendererAttacher()
        attacher.waitForCodex()
        expect(attacher.state == .waitingForCodex, "attacher waits without injecting")
        attacher.attach(to: wrongBundle)
        expect(
            attacher.state == .unavailable(.wrongProcessTarget),
            "attacher rejects the wrong process"
        )
        attacher.attach(to: target)
        expect(
            attacher.state == .unavailable(.noApprovedStockEndpoint),
            "attacher fails closed without a stock endpoint"
        )
        attacher.stop()
        expect(attacher.state == .idle, "attacher cleanup returns to idle")

        let fakeWatcher = FakeCodexProcessWatcher()
        let controllerAttacher = CodexRendererAttacher()
        let controller = CodexM0RuntimeController(
            enabled: true,
            watcher: fakeWatcher,
            attacher: controllerAttacher
        )
        controller.start()
        controller.start()
        expect(fakeWatcher.startCount == 1, "controller start is idempotent")
        fakeWatcher.emit(.running(processIdentifier: 42))
        expect(
            controller.state == .unavailable(.noApprovedStockEndpoint),
            "running Codex reaches fail-closed attach state"
        )
        fakeWatcher.emit(.waitingForCodex)
        expect(controller.state == .waitingForCodex, "Codex exit cleans renderer state")
        controller.stop()
        controller.stop()
        expect(fakeWatcher.stopCount == 1, "controller cleanup is idempotent")
        expect(controller.state == .idle, "controller stop returns to idle")

        let disabledWatcher = FakeCodexProcessWatcher()
        let disabledController = CodexM0RuntimeController(
            enabled: false,
            watcher: disabledWatcher
        )
        disabledController.start()
        expect(disabledWatcher.startCount == 0, "release gate keeps M0 disabled")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("M0 tests passed")
    }
}
