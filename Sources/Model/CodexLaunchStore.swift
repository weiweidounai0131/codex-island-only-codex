import AppKit
import Combine
import Foundation

enum CodexRendererLaunch {
    static let defaultPort: UInt16 = 43123

    static func arguments(for port: UInt16 = defaultPort) -> [String] {
        ["--remote-debugging-port=\(port)"]
    }
}

enum CodexLaunchState: Equatable {
    case idle
    case launching
    case ready
    case failed
}

/// Provides a one-click compatible launch for the official Codex app.
///
/// This is deliberately a launcher, not a wrapper: it starts the unchanged
/// official executable with one explicit Chromium Renderer argument and does
/// not add Host Runtime, app-server, plugin, or credential environment.
@MainActor
final class CodexLaunchStore: ObservableObject {
    static let shared = CodexLaunchStore()

    @Published private(set) var state: CodexLaunchState = .idle

    var subtitleKey: String {
        switch state {
        case .idle:
            return "Use the official Codex executable with --remote-debugging-port=43123."
        case .launching:
            return "Launching the official Codex app with the local Renderer endpoint."
        case .ready:
            return "Official Codex is running with the local Renderer endpoint."
        case .failed:
            return "The official Codex app could not be found."
        }
    }

    var buttonLabelKey: String {
        switch state {
        case .launching:
            return "Launching…"
        case .idle, .failed:
            return "Launch Codex"
        case .ready:
            return "Open Codex"
        }
    }

    var isLaunching: Bool {
        state == .launching
    }

    func launch() {
        guard state != .launching else { return }
        guard let applicationURL = officialApplicationURL(),
              let executableURL = officialExecutableURL(applicationURL) else {
            state = .failed
            return
        }

        if let running = runningOfficialApplication() {
            if let commandLine = commandLine(for: running.processIdentifier),
               CodexInspectorDiscovery.rendererPort(in: commandLine) != nil {
                running.activate(options: [.activateAllWindows])
                state = .ready
                return
            }

            guard confirmRelaunch() else {
                state = .idle
                return
            }
            state = .launching
            guard running.terminate() else {
                state = .failed
                return
            }
            waitForTermination(of: running, executableURL: executableURL)
            return
        }

        start(executableURL: executableURL)
    }

    private func start(executableURL: URL) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = CodexRendererLaunch.arguments()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            state = .ready
        } catch {
            state = .failed
        }
    }

    private func waitForTermination(of application: NSRunningApplication, executableURL: URL) {
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            guard state == .launching else { return }
            if application.isTerminated {
                start(executableURL: executableURL)
                return
            }
            if Date() >= deadline {
                state = .failed
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                poll()
            }
        }
        poll()
    }

    private func confirmRelaunch() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Codex is already running without the CH endpoint.")
        alert.informativeText = L10n.tr(
            "To enable conversation usage, CodexIsland needs to relaunch the official Codex app. Unsaved work may be interrupted."
        )
        alert.addButton(withTitle: L10n.tr("Restart Codex"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func officialApplicationURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: CodexProcessWatcherCore.targetBundleIdentifier
        ) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func officialExecutableURL(_ applicationURL: URL) -> URL? {
        let executable = applicationURL.appendingPathComponent("Contents/MacOS/ChatGPT")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    private func runningOfficialApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexProcessWatcherCore.targetBundleIdentifier
        )
        .sorted { $0.processIdentifier < $1.processIdentifier }
        .first
    }

    private func commandLine(for processIdentifier: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(processIdentifier), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
    }
}
