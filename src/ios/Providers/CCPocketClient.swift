import Foundation

/// WebSocket client for a CC Pocket Bridge Server.
///
/// Owns the connection lifecycle (connect / send / receive / disconnect)
/// and exposes the server message stream to the provider layer.
/// Reconnect strategy is deliberately basic in M1 (connect once, fail with
/// an error) — full reconnect/queueing lands in M4.
final class CCPocketClient: @unchecked Sendable {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle
    private let logger = AppLogger(category: "CCPocketClient")

    /// Active agent session id, captured from the Bridge's `system` reply to
    /// our `start`. The receive loop captures it regardless of whether a
    /// per-turn onMessage handler is installed yet (the start reply can land
    /// before the provider sets one up), so subsequent `input` messages always
    /// carry the session.
    private(set) var sessionId: String?

    private let baseURL: URL
    private let token: String
    private var task: URLSessionWebSocketTask?

    /// Connection parameters retained for auto-reconnect (send failure after
    /// the app is suspended / network drops). Reconnect resumes the agent
    /// session via StartRequest.sessionId so conversation context survives.
    private var projectPath: String?
    private var providerName: String = "claude"
    private var permissionMode: String?
    private var receiveTask: Task<Void, Never>?

    /// Single active consumer of the server message stream. The provider
    /// installs a handler per turn; a turn ends when the handler sees a
    /// `result` (or error). Sequential turns are the M1 contract.
    var onMessage: ((CCPocketProtocol.ServerMessage) -> Void)?

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Connection

    /// Connect to the Bridge. `projectPath` is the working directory the
    /// Bridge should open the agent session in.
    func connect(projectPath: String, provider: String = "claude", permissionMode: String? = nil, resumeSessionId: String? = nil) async throws {
        // [Diag]
        logger.info("[CCPocket] connect url=\(baseURL.absoluteString) projectPath=\(projectPath) provider=\(provider) perm=\(permissionMode ?? "default") resume=\(resumeSessionId ?? "none") state=\(state == .idle ? "idle" : "busy")")
        guard state == .idle else {
            logger.warning("[CCPocket] connect skipped — state not idle")
            return
        }

        self.projectPath = projectPath
        self.providerName = provider
        self.permissionMode = permissionMode

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else {
            throw CCPocketError.invalidURL
        }

        state = .connecting
        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        state = .connected
        logger.info("[CCPocket] ws connected")

        // Announce client capabilities first; Bridge replies with history/state.
        let capabilities = CCPocketProtocol.ClientCapabilities()
        try await send(CCPocketProtocol.encode(capabilities), allowsReconnect: false)

        // Start an agent session on this project path. When reconnecting after
        // a dropped socket, pass the previous session id so the Bridge resumes
        // the same agent conversation instead of starting a fresh one.
        let start = CCPocketProtocol.StartRequest(
            projectPath: projectPath,
            provider: provider,
            sessionId: resumeSessionId,
            continue: resumeSessionId != nil ? true : nil,
            requestId: UUID().uuidString,
            permissionMode: permissionMode
        )
        try await send(CCPocketProtocol.encode(start), allowsReconnect: false)
        logger.info("[CCPocket] start sent")

        startReceiveLoop()
    }

    /// Continuously receive server messages and dispatch to the active handler.
    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await self.task?.receive()
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let serverMessage = CCPocketProtocol.decodeServerMessage(data) {
                            self.captureSession(from: serverMessage)
                            self.onMessage?(serverMessage)
                        }
                    case .data(let data):
                        if let serverMessage = CCPocketProtocol.decodeServerMessage(data) {
                            self.captureSession(from: serverMessage)
                            self.onMessage?(serverMessage)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    self.state = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    /// Capture the agent session id from any `system` message (the Bridge's
    /// reply to `start`). Runs on every message so the session is captured
    /// even when no per-turn handler is installed yet.
    private func captureSession(from message: CCPocketProtocol.ServerMessage) {
        if message.type == "system",
           let sid = message.sessionId ?? message.claudeSessionId {
            sessionId = sid
        }
    }

    // MARK: - Sending

    func sendInput(_ text: String, sessionId: String? = nil) async throws {
        let input = CCPocketProtocol.InputRequest(
            text: text,
            sessionId: sessionId,
            clientMessageId: UUID().uuidString
        )
        try await send(CCPocketProtocol.encode(input))
    }

    private func send(_ string: String, allowsReconnect: Bool = true) async throws {
        guard let task else { throw CCPocketError.notConnected }
        do {
            try await task.send(.string(string))
        } catch {
            // Socket died underneath us (app suspended, network switch). The
            // receive loop may never have observed the error (process was
            // suspended), so state still says connected — reconnect with the
            // agent session resumed, then retry this message once.
            logger.warning("[CCPocket] send failed (\(error.localizedDescription)) — reconnecting and retrying once")
            let resumeSessionId = sessionId
            disconnect()
            guard allowsReconnect, let projectPath else {
                throw error
            }
            do {
                try await connect(
                    projectPath: projectPath,
                    provider: providerName,
                    permissionMode: permissionMode,
                    resumeSessionId: resumeSessionId
                )
            } catch {
                throw error
            }
            guard let task else { throw CCPocketError.notConnected }
            try await task.send(.string(string))
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onMessage = nil
        state = .idle
    }

    deinit {
        disconnect()
    }
}

enum CCPocketError: LocalizedError {
    case invalidURL
    case notConnected
    case sessionNotStarted
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Bridge URL"
        case .notConnected: return "Not connected to Bridge"
        case .sessionNotStarted: return "Agent session has not started"
        case .server(let message): return "Bridge error: \(message)"
        }
    }
}
