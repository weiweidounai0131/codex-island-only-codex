import Foundation
import Darwin

private struct HookActivityEvent: Encodable {
    let kind: String
    let sessionID: String
    let taskID: String?
    let occurredAt: TimeInterval
}

private let maximumInputBytes = 2_097_152

@main
struct CodexIslandTaskActivityHook {
    static func main() {
        guard let queuePath = argumentValue(named: "--queue") else { return }
        guard let object = readInput(),
              let hookEvent = stringValue(in: object, keys: ["hook_event_name", "event", "type"]),
              let kind = activityKind(for: hookEvent),
              let sessionID = stringValue(
                  in: object,
                  keys: ["session_id", "sessionId", "thread_id", "threadId"]
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else { return }

        let queueURL = URL(fileURLWithPath: queuePath, isDirectory: true)
        guard isSafeQueueDirectory(queueURL) else { return }

        let event = HookActivityEvent(
            kind: kind,
            sessionID: sessionID,
            taskID: stringValue(in: object, keys: ["turn_id", "turnId"]),
            occurredAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(event) else { return }
        write(data, to: queueURL)
    }

    private static func argumentValue(named name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func readInput() -> [String: Any]? {
        var data = Data()
        while data.count <= maximumInputBytes {
            let remaining = maximumInputBytes + 1 - data.count
            let chunk: Data?
            do {
                chunk = try FileHandle.standardInput.read(
                    upToCount: min(65_536, remaining)
                )
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maximumInputBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func activityKind(for hookEvent: String) -> String? {
        switch hookEvent {
        case "UserPromptSubmit":
            return "UserPromptSubmit"
        case "Stop":
            return "Stop"
        case "SessionEnd":
            return "SessionEnd"
        case "PreToolUse", "PermissionRequest", "PostToolUse",
             "PreCompact", "PostCompact", "SubagentStart", "SubagentStop":
            return "TurnActivity"
        default:
            return nil
        }
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }

        for nestedKey in ["payload", "context", "session"] {
            if let nested = object[nestedKey] as? [String: Any],
               let value = stringValue(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func isSafeQueueDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            return false
        }
        return true
    }

    private static func write(_ data: Data, to directoryURL: URL) {
        let id = UUID().uuidString
        let temporaryURL = directoryURL.appendingPathComponent(".event-\(id).tmp")
        let timestamp = String(
            format: "%020llu",
            UInt64(Date().timeIntervalSince1970 * 1_000_000)
        )
        let eventURL = directoryURL.appendingPathComponent("event-\(timestamp)-\(id).json")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return }

        var success = true
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                success = false
                return
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                guard count > 0 else {
                    success = false
                    return
                }
                offset += count
            }
        }
        _ = fsync(descriptor)
        close(descriptor)

        guard success, rename(temporaryURL.path, eventURL.path) == 0 else {
            unlink(temporaryURL.path)
            return
        }
    }
}
