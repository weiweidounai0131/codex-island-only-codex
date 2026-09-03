import Foundation
import Network

struct CodexInspectorEndpoint: Sendable {
    let webSocketURL: URL
}

enum CodexInspectorError: LocalizedError {
    case endpointUnavailable
    case invalidResponse
    case protocolError(String)
    case noExplicitRendererEndpoint
    case rendererUnavailable

    var errorDescription: String? {
        switch self {
        case .endpointUnavailable:
            return "Codex Inspector endpoint is unavailable."
        case .invalidResponse:
            return "Codex Inspector returned an invalid response."
        case .protocolError(let message):
            return "Codex Inspector protocol error: \(message)"
        case .noExplicitRendererEndpoint:
            return "Codex was not launched with an explicit loopback Renderer endpoint."
        case .rendererUnavailable:
            return "Codex renderer is unavailable."
        }
    }
}

private final class CodexInspectorWebSocket: @unchecked Sendable {
    private let url: URL
    private let connection: NWConnection
    private var readBuffer = Data()
    private var connected = false
    private var closed = false

    init(url: URL) throws {
        guard let host = url.host,
              let portValue = url.port,
              portValue <= Int(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw CodexInspectorError.invalidResponse
        }
        self.url = url
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: .tcp
        )
    }

    func connect() async throws {
        guard !connected, !closed else { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let stateLock = NSLock()
            var finished = false
            let finish: (Result<Void, Error>) -> Void = { [weak self] result in
                stateLock.lock()
                guard !finished else {
                    stateLock.unlock()
                    return
                }
                finished = true
                stateLock.unlock()
                self?.connection.stateUpdateHandler = nil
                switch result {
                case .success:
                    self?.connected = true
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CodexInspectorError.protocolError("socket cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
        }

        let keyBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let path = connectionPath()
        let host = "\(connectionHost()):\(connectionPort())"
        let request = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "",
            ""
        ].joined(separator: "\r\n")
        try await sendRaw(Data(request.utf8))

        let separator = Data([13, 10, 13, 10])
        while readBuffer.range(of: separator) == nil {
            readBuffer.append(try await receiveRaw())
        }
        guard let range = readBuffer.range(of: separator) else {
            throw CodexInspectorError.invalidResponse
        }
        let headerData = Data(readBuffer[..<range.upperBound])
        readBuffer.removeSubrange(..<range.upperBound)
        let header = String(decoding: headerData, as: UTF8.self)
        guard header.hasPrefix("HTTP/1.1 101") || header.hasPrefix("HTTP/1.0 101") else {
            throw CodexInspectorError.protocolError("WebSocket upgrade was rejected")
        }
    }

    func sendText(_ text: String) async throws {
        try await sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func receiveText() async throws -> String {
        var message = Data()
        var expectingContinuation = false
        while true {
            let frame = try await receiveFrame()
            switch frame.opcode {
            case 0x1 where !expectingContinuation:
                message = frame.payload
                if frame.fin {
                    return String(decoding: message, as: UTF8.self)
                }
                expectingContinuation = true
            case 0x0 where expectingContinuation:
                message.append(frame.payload)
                if frame.fin {
                    return String(decoding: message, as: UTF8.self)
                }
            case 0x8:
                close()
                throw CodexInspectorError.protocolError("WebSocket closed")
            case 0x9:
                try await sendFrame(opcode: 0xA, payload: frame.payload)
            case 0xA:
                continue
            default:
                continue
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    private struct Frame {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
    }

    private func sendFrame(opcode: UInt8, payload: Data) async throws {
        var frame = Data()
        frame.append(UInt8(0x80 | opcode))
        let length = payload.count
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        if length < 126 {
            frame.append(UInt8(0x80 | length))
        } else if length <= Int(UInt16.max) {
            frame.append(UInt8(0x80 | 126))
            frame.append(UInt8((length >> 8) & 0xff))
            frame.append(UInt8(length & 0xff))
        } else {
            frame.append(UInt8(0x80 | 127))
            let value = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((value >> UInt64(shift)) & 0xff))
            }
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { index, byte in
            byte ^ mask[index % 4]
        })
        try await sendRaw(frame)
    }

    private func receiveFrame() async throws -> Frame {
        while true {
            guard readBuffer.count >= 2 else {
                readBuffer.append(try await receiveRaw())
                continue
            }
            let first = readBuffer[readBuffer.startIndex]
            let second = readBuffer[readBuffer.startIndex + 1]
            let fin = (first & 0x80) != 0
            let opcode = first & 0x0f
            let masked = (second & 0x80) != 0
            var offset = 2
            var length = UInt64(second & 0x7f)

            if length == 126 {
                while readBuffer.count < offset + 2 {
                    readBuffer.append(try await receiveRaw())
                }
                length = UInt64(readBuffer[offset]) << 8
                    | UInt64(readBuffer[offset + 1])
                offset += 2
            } else if length == 127 {
                while readBuffer.count < offset + 8 {
                    readBuffer.append(try await receiveRaw())
                }
                length = 0
                for index in 0..<8 {
                    length = (length << 8) | UInt64(readBuffer[offset + index])
                }
                offset += 8
            }

            guard length <= UInt64(16 * 1024 * 1024),
                  let payloadLength = Int(exactly: length) else {
                throw CodexInspectorError.protocolError("WebSocket frame is too large")
            }
            let maskLength = masked ? 4 : 0
            let totalLength = offset + maskLength + payloadLength
            while readBuffer.count < totalLength {
                readBuffer.append(try await receiveRaw())
            }

            var mask: [UInt8] = []
            if masked {
                mask = (0..<4).map { readBuffer[offset + $0] }
                offset += 4
            }
            var payload = (0..<payloadLength).map { readBuffer[offset + $0] }
            readBuffer.removeSubrange(0..<totalLength)
            if masked {
                for index in payload.indices {
                    payload[index] ^= mask[index % 4]
                }
            }
            return Frame(fin: fin, opcode: opcode, payload: Data(payload))
        }
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func receiveRaw() async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(
                        throwing: CodexInspectorError.protocolError("socket closed")
                    )
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func connectionPath() -> String {
        url.path.isEmpty ? "/" : url.path
    }

    private func connectionHost() -> String {
        url.host ?? "127.0.0.1"
    }

    private func connectionPort() -> Int {
        url.port ?? 9229
    }
}

/// Small CDP client used only for the explicit loopback Chromium Renderer
/// endpoint opened by the official Codex process. Commands are serialized by
/// the caller and no browser or app-server protocol is exposed here.
final class CodexInspectorClient: @unchecked Sendable {
    private let socket: CodexInspectorWebSocket
    private var nextCommandID = 1

    init(endpoint: CodexInspectorEndpoint) throws {
        socket = try CodexInspectorWebSocket(url: endpoint.webSocketURL)
    }

    deinit {
        close()
    }

    func waitUntilConnected() async throws {
        try await socket.connect()
    }

    func command(
        method: String,
        parameters: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let commandID = nextCommandID
        nextCommandID += 1
        let message: [String: Any] = [
            "id": commandID,
            "method": method,
            "params": parameters
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexInspectorError.invalidResponse
        }
        try await socket.sendText(text)

        while true {
            let response = try await socket.receiveText()
            guard let object = try JSONSerialization.jsonObject(with: Data(response.utf8))
                    as? [String: Any] else {
                throw CodexInspectorError.invalidResponse
            }

            guard let responseID = (object["id"] as? NSNumber)?.intValue,
                  responseID == commandID else {
                continue
            }

            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown error"
                throw CodexInspectorError.protocolError(message)
            }
            return object["result"] as? [String: Any] ?? [:]
        }
    }

    func evaluate(_ expression: String) async throws -> Any? {
        let response = try await command(
            method: "Runtime.evaluate",
            parameters: [
                "expression": expression,
                "awaitPromise": true,
                "returnByValue": true
            ]
        )
        if let exception = response["exceptionDetails"] as? [String: Any] {
            let text = exception["text"] as? String ?? "renderer evaluation failed"
            throw CodexInspectorError.protocolError(text)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CodexInspectorError.invalidResponse
        }
        return result["value"]
    }

    func close() {
        socket.close()
    }
}

enum CodexInspectorDiscovery {
    /// Parse the only endpoint this app is allowed to use. A normal
    /// LaunchServices-launched Codex has no endpoint and must remain untouched.
    static func rendererPort(in commandLine: String) -> UInt16? {
        let prefix = "--remote-debugging-port="
        // `ps` terminates its output with a newline. Treat all Unicode
        // whitespace as a delimiter so the port is parsed exactly as it was
        // written in the explicit launch argument.
        for token in commandLine.split(whereSeparator: { $0.isWhitespace }) {
            let value = String(token)
            guard value.hasPrefix(prefix) else { continue }
            let rawPort = String(value.dropFirst(prefix.count))
            guard let port = Int(rawPort),
                  port > 0,
                  port <= Int(UInt16.max) else {
                continue
            }
            return UInt16(port)
        }
        return nil
    }

    private static func commandLine(for processIdentifier: Int32) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(processIdentifier), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodexInspectorError.endpointUnavailable
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    static func discover(for processIdentifier: Int32) async throws -> CodexInspectorEndpoint {
        let commandLine = try commandLine(for: processIdentifier)
        let port = rendererPort(in: commandLine)
        guard let port else {
            throw CodexInspectorError.noExplicitRendererEndpoint
        }
        let endpointURL = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let (data, response) = try await URLSession.shared.data(from: endpointURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CodexInspectorError.endpointUnavailable
        }

        for value in values where value["type"] as? String == "page" {
            if (value["url"] as? String)?.hasPrefix("app://") != true {
                continue
            }
            guard let rawURL = value["webSocketDebuggerUrl"] as? String,
                  let webSocketURL = URL(string: rawURL),
                  webSocketURL.scheme == "ws",
                  ["127.0.0.1", "localhost", "::1", "[::1]"].contains(webSocketURL.host ?? "") else {
                continue
            }
            return CodexInspectorEndpoint(webSocketURL: webSocketURL)
        }
        throw CodexInspectorError.endpointUnavailable
    }

    static func connect(
        to processIdentifier: Int32,
        timeout: TimeInterval = 5
    ) async throws -> CodexInspectorClient {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                let endpoint = try await discover(for: processIdentifier)
                let client = try CodexInspectorClient(endpoint: endpoint)
                do {
                    try await client.waitUntilConnected()
                    let location = try await client.evaluate(
                        "String(location.protocol) + String(location.host)"
                    )
                    guard let location = location as? String,
                          location.hasPrefix("app:") else {
                        throw CodexInspectorError.rendererUnavailable
                    }
                    return client
                } catch {
                    client.close()
                    throw error
                }
            } catch let error as CodexInspectorError {
                if case .noExplicitRendererEndpoint = error {
                    break
                }
                lastError = error
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw lastError ?? CodexInspectorError.endpointUnavailable
    }
}

enum CodexRendererInspectorAttachment {
    private static let visibleThreadExpression = """
    (() => {
      const roots = [...document.querySelectorAll('[data-codex-composer-root], [data-codex-composer]')];
      const visible = roots.filter((element) => element.getClientRects().length > 0);
      const composer = visible[0] ?? roots[0] ?? null;
      if (!composer) return null;
      const ids = [...new Set(
        [...composer.querySelectorAll('[data-above-composer-conversation-id]')]
          .map((element) => element.getAttribute('data-above-composer-conversation-id'))
          .filter((value) => typeof value === 'string' && value.length > 0),
      )];
      return ids.length === 1 ? ids[0] : null;
    })()
    """

    private static func installDirectlyInRenderer(
        client: CodexInspectorClient,
        hudSource: String,
        bridgeSource: String,
        snapshotJSON: String?,
        enabled: Bool
    ) async throws -> String? {
        let escapedHUD = try jsonString(hudSource)
        let escapedBridge = try jsonString(bridgeSource)
        let escapedSnapshot = snapshotJSON.flatMap { try? jsonString($0) }
        let bootstrap = rendererBootstrap(
            enabled: enabled,
            snapshotJSON: escapedSnapshot
        )
        let escapedBootstrap = try jsonString(bootstrap)
        let bridgeActivation = try jsonString(
            "window.__codexIslandCacheHUDBridgeV1?.setEnabled(\(enabled ? "true" : "false")); true"
        )

        let expression = """
        (async () => {
          globalThis.eval(\(escapedHUD));
          globalThis.eval(\(escapedBridge));
          globalThis.eval(\(bridgeActivation));
          globalThis.eval(\(escapedBootstrap));
          return true;
        })()
        """
        _ = try await client.evaluate(expression)
        return try await client.evaluate(visibleThreadExpression) as? String
    }

    static func install(
        processIdentifier: Int32,
        hudSource: String,
        bridgeSource: String,
        snapshotJSON: String?,
        enabled: Bool
    ) async throws -> String? {
        let client = try await CodexInspectorDiscovery.connect(to: processIdentifier)
        defer { client.close() }
        return try await installDirectlyInRenderer(
            client: client,
            hudSource: hudSource,
            bridgeSource: bridgeSource,
            snapshotJSON: snapshotJSON,
            enabled: enabled
        )
    }

    private static func rendererBootstrap(
        enabled: Bool,
        snapshotJSON: String?
    ) -> String {
        let snapshot = snapshotJSON.map { "api.setSnapshot(\($0));" } ?? ""
        return """
        (() => {
          const api = window.__codexIslandCacheHUDV1;
          if (!api) throw new Error('Cache HUD API unavailable');
          api.setEnabled(\(enabled ? "true" : "false"));
          \(snapshot)
          return api.inspect();
        })()
        """
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            throw CodexInspectorError.invalidResponse
        }
        return String(encoded.dropFirst().dropLast())
    }
}
