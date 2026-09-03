import Foundation

/// Reads Codex's local session JSONL without entering the cost pipeline.
///
/// A token_count record is accepted only after a turn_context record has
/// supplied both a session id and a turn id. This is deliberately stricter
/// than "newest rollout wins": concurrent conversations must never share a
/// CH value just because one file was modified most recently.
final class CodexCacheHitReader: @unchecked Sendable {
    let directoryURL: URL
    let lookback: TimeInterval
    private let fileManager: FileManager
    private let cacheLock = NSLock()
    private var fileCache: [String: CachedFile] = [:]

    private struct CachedFile {
        let modifiedAt: Date
        let size: Int64
        let snapshots: [CodexCacheHitSnapshot]
    }

    init(
        directoryURL: URL? = nil,
        lookbackDays: Int = 7,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
            ?? Self.defaultSessionsRoot(fileManager: fileManager)
        self.lookback = TimeInterval(max(1, lookbackDays)) * 86_400
        self.fileManager = fileManager
    }

    func read(now: Date = Date()) -> [CodexCacheHitSnapshot] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var snapshots: [CodexCacheHitSnapshot] = []
        var seenPaths: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  let fileSize = values.fileSize,
                  now.timeIntervalSince(modifiedAt) <= lookback else {
                continue
            }

            let path = url.path
            seenPaths.insert(path)
            if let cached = cachedFile(path: path, modifiedAt: modifiedAt, size: Int64(fileSize)) {
                snapshots.append(contentsOf: cached)
            } else {
                let parsed = parseFile(at: url)
                cacheFile(
                    path: path,
                    modifiedAt: modifiedAt,
                    size: Int64(fileSize),
                    snapshots: parsed
                )
                snapshots.append(contentsOf: parsed)
            }
        }

        cacheLock.lock()
        fileCache = fileCache.filter { seenPaths.contains($0.key) }
        cacheLock.unlock()

        return snapshots.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
            return $0.turnID < $1.turnID
        }
    }

    private func cachedFile(path: String, modifiedAt: Date, size: Int64)
        -> [CodexCacheHitSnapshot]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = fileCache[path],
              cached.size == size,
              abs(cached.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001 else {
            return nil
        }
        return cached.snapshots
    }

    private func cacheFile(
        path: String,
        modifiedAt: Date,
        size: Int64,
        snapshots: [CodexCacheHitSnapshot]
    ) {
        cacheLock.lock()
        fileCache[path] = CachedFile(
            modifiedAt: modifiedAt,
            size: size,
            snapshots: snapshots
        )
        cacheLock.unlock()
    }

    private func parseFile(at url: URL) -> [CodexCacheHitSnapshot] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterNoFractional = ISO8601DateFormatter()
        formatterNoFractional.formatOptions = [.withInternetDateTime]

        var sessionID = Self.fallbackSessionID(from: url)
        var currentTurnID: String?
        var currentModel: String?
        var latestByTurn: [String: CodexCacheHitSnapshot] = [:]

        LogParseCache.streamLines(at: url, maxLineBytes: 1 << 20) { lineData in
            guard let raw = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any],
                  let type = raw["type"] as? String else {
                return
            }

            if type == "session_meta",
               let payload = raw["payload"] as? [String: Any] {
                sessionID = Self.stringValue(payload["id"])
                    ?? Self.stringValue(payload["session_id"])
                    ?? sessionID
                return
            }

            if type == "turn_context",
               let payload = raw["payload"] as? [String: Any] {
                currentTurnID = Self.stringValue(payload["turn_id"])
                currentModel = Self.stringValue(payload["model"])
                return
            }

            guard type == "event_msg",
                  let payload = raw["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let sessionID,
                  let currentTurnID else {
                return
            }

            // CodexHost uses the cumulative total for the breakdown and the
            // latest request for CH. Keep the same split for local bootstrap
            // snapshots so the renderer and JSONL paths agree.
            let total = info["total_token_usage"] as? [String: Any] ?? last
            let inputTokens = Self.nonNegativeInt(total["input_tokens"]) ?? 0
            let cachedInputTokens = Self.nonNegativeInt(total["cached_input_tokens"]) ?? 0
            let cacheWriteInputTokens = Self.nonNegativeInt(total["cache_write_input_tokens"]) ?? 0
            let outputTokens = Self.nonNegativeInt(total["output_tokens"]) ?? 0
            let reasoningOutputTokens =
                Self.nonNegativeInt(total["reasoning_output_tokens"]) ?? 0
            let totalTokens = Self.nonNegativeInt(total["total_tokens"])
                ?? inputTokens + outputTokens + reasoningOutputTokens
            let lastTotalTokens = Self.nonNegativeInt(last["total_tokens"])
            let lastInputTokens = Self.nonNegativeInt(last["input_tokens"])
            let lastCachedInputTokens = Self.nonNegativeInt(last["cached_input_tokens"])
            let contextWindow = Self.nonNegativeInt(info["model_context_window"])
                ?? Self.nonNegativeInt(raw["model_context_window"])
            let timestampString = Self.stringValue(raw["timestamp"]) ?? ""
            let timestamp = formatter.date(from: timestampString)
                ?? formatterNoFractional.date(from: timestampString)
                ?? Date.distantPast

            let snapshot = CodexCacheHitSnapshot(
                sessionID: sessionID,
                turnID: currentTurnID,
                timestamp: timestamp,
                model: currentModel,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                totalTokens: totalTokens,
                modelContextWindow: contextWindow,
                cacheWriteInputTokens: cacheWriteInputTokens,
                lastTotalTokens: lastTotalTokens,
                lastInputTokens: lastInputTokens,
                lastCachedInputTokens: lastCachedInputTokens
            )
            guard snapshot.hasUsage else { return }

            if let previous = latestByTurn[currentTurnID], previous.timestamp > timestamp {
                return
            }
            latestByTurn[currentTurnID] = snapshot
        }

        return latestByTurn.values.sorted { $0.timestamp < $1.timestamp }
    }

    private static func defaultSessionsRoot(fileManager: FileManager) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static func fallbackSessionID(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        if let value = value as? Int, value >= 0 { return value }
        if let value = value as? NSNumber, value.int64Value >= 0,
           value.int64Value <= Int64(Int.max) {
            return Int(value.int64Value)
        }
        if let value = value as? String, let parsed = Int(value), parsed >= 0 {
            return parsed
        }
        return nil
    }
}
