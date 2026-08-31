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

    /// Active Bridge session id (short, 8 chars), captured from the Bridge's
    /// `system` reply to our `start`. Used to route `input` messages — the
    /// Bridge resolves them by exact Bridge session id. The receive loop
    /// captures it regardless of whether a per-turn onMessage handler is
    /// installed yet (the start reply can land before the provider sets one
    /// up), so subsequent `input` messages always carry the session.
    private(set) var sessionId: String?

    /// Claude agent session id (full UUID, 36 chars) — the only id the SDK
    /// `resume` option accepts. Arrives via the `claudeSessionId` field, a
    /// long `sessionId` on system/result messages (the Bridge captures it
    /// from the SDK result event), or the `session_list` payload (sent on
    /// every connection). Kept separate from `sessionId` (the 8-char Bridge
    /// id): routing `input` and resuming an agent conversation are different
    /// id spaces.
    private(set) var claudeSessionId: String?

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

    /// Keep-alive ping task. iOS WebSocket connections can be silently
    /// dropped by NAT/middleboxes after ~2-3 minutes of inactivity; a
    /// periodic ping keeps the mapping alive so a foreground session does
    /// not drop mid-conversation (each drop forces a reconnect, and without
    /// a resume id that means a brand-new agent session).
    private var pingTask: Task<Void, Never>?
    private static let pingIntervalNanoseconds: UInt64 = 30_000_000_000

    /// Single active consumer of the server message stream. The provider
    /// installs a handler per turn; a turn ends when the handler sees a
    /// `result` (or error). Sequential turns are the M1 contract.
    var onMessage: ((CCPocketProtocol.ServerMessage) -> Void)?

    /// UserDefaults key for the persisted Bridge agent session id per project.
    /// Killing the app loses the in-memory session id; persisting it lets the
    /// next launch resume the same agent conversation instead of the Bridge
    /// starting a brand-new one (which answers like a stranger).
    private static let sessionKeyPrefix = "ccpocket.agentSession.v1."

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

        // Start an agent session on this project path. Resume the previous
        // agent conversation when available (reconnect, or app relaunch after
        // a kill — the in-memory id is gone but the persisted one survives).
        // [Fix] Resume with the *Claude* session id only, and never combine
        // it with `continue`: the SDK falls back to "continue the most
        // recent session" when a resume id is invalid, which hijacks an
        // unrelated conversation (cross-session message bleed). M1 stored the
        // 8-char Bridge id here, which was never a valid resume target.
        let effectiveResumeId = resumeSessionId
            ?? persistedResumeId(projectPath: projectPath)
        let start = CCPocketProtocol.StartRequest(
            projectPath: projectPath,
            provider: provider,
            sessionId: effectiveResumeId,
            continue: nil,
            requestId: UUID().uuidString,
            permissionMode: permissionMode
        )
        try await send(CCPocketProtocol.encode(start), allowsReconnect: false)
        logger.info("[CCPocket] start sent")

        startReceiveLoop()
        startPing()
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

    /// Capture the Bridge session id and the Claude session id from incoming
    /// messages. Runs on every message so ids are captured even when no
    /// per-turn handler is installed yet.
    ///
    /// [Fix] M1 stored whatever `sessionId` the first `system` message
    /// carried — which is the 8-char *Bridge* id, useless for SDK resume.
    /// Two separate ids are tracked now:
    /// - `sessionId` (8 chars): routes `input` (Bridge resolves exactly).
    /// - `claudeSessionId` (36 chars): the SDK `resume` target. It arrives
    ///   via an explicit `claudeSessionId` field, or as a long `sessionId`
    ///   on system/result messages (the Bridge captures the Claude id from
    ///   the SDK result event). Only this id is persisted for relaunch
    ///   resume.
    private func captureSession(from message: CCPocketProtocol.ServerMessage) {
        // Bridge session id — short (8 chars), on the `system` reply.
        // [Diag] Log the raw value so a missing capture is explainable from
        // device logs alone (e.g. the Bridge sending a long id here).
        if message.type == "system" {
            if let raw = message.sessionId {
                if raw.count <= 8, raw != sessionId {
                    sessionId = raw
                    logger.info("[CCPocket] captured bridgeSessionId=\(raw) msg=\(message.subtype ?? "system")")
                } else if raw.count > 8 {
                    logger.info("[CCPocket] system msg has long sessionId (claude id, len=\(raw.count)) — not a bridge routing id")
                }
            } else if sessionId == nil {
                logger.info("[CCPocket] system msg without sessionId (\(message.subtype ?? "?"))")
            }
        }
        // Claude session id — full UUID (36 chars).
        let claudeId: String?
        if let explicit = message.claudeSessionId {
            claudeId = explicit
        } else if let raw = message.sessionId, raw.count > 8 {
            claudeId = raw
        } else {
            claudeId = nil
        }
        if let claudeId, claudeId != claudeSessionId {
            claudeSessionId = claudeId
            if let projectPath {
                UserDefaults.standard.set(claudeId, forKey: Self.sessionKeyPrefix + projectPath)
            }
            logger.info("[CCPocket] captured claudeSessionId=\(claudeId.prefix(8))... msg=\(message.type ?? "?")")
        }
        // `session_list` (Bridge sends it on every connection) carries the
        // authoritative claudeSessionId per Bridge session — match by our
        // Bridge session id and persist it. This is the reliable resume
        // source even when no `result` has landed yet (e.g. reconnect before
        // the first turn completes).
        if let sessions = message.sessions,
           let sessionId,
           let match = sessions.first(where: { $0.id == sessionId }),
           let claudeId = match.claudeSessionId,
           claudeId != claudeSessionId {
            claudeSessionId = claudeId
            if let projectPath {
                UserDefaults.standard.set(claudeId, forKey: Self.sessionKeyPrefix + projectPath)
            }
            logger.info("[CCPocket] captured claudeSessionId from session_list=\(claudeId.prefix(8))...")
        }
    }

    /// Periodic ping to keep the WebSocket alive through NAT/middleboxes.
    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalNanoseconds)
                guard !Task.isCancelled else { break }
                // sendPing is not async; a dead socket surfaces on the next
                // send (or this ping errors, which we deliberately ignore —
                // the send path owns reconnecting).
                self.task?.sendPing(pongReceiveHandler: { _ in })
            }
        }
    }

    /// Claude session id persisted for this project, if it is usable for
    /// resume. An 8-char value is a stale Bridge session id written by M1 —
    /// invalid as an SDK resume target and harmful when combined with
    /// `continue` (hijacks the most recent session) — so it is dropped.
    private func persistedResumeId(projectPath: String) -> String? {
        let key = Self.sessionKeyPrefix + projectPath
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        guard raw.count > 8 else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return raw
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
            // [Fix] Resume the *Claude* session (not the 8-char Bridge id):
            // only the Claude id is a valid SDK resume target.
            let resumeSessionId = claudeSessionId
            disconnect()
            guard allowsReconnect, let projectPath else {
                throw error
            }
            try await connect(
                projectPath: projectPath,
                provider: providerName,
                permissionMode: permissionMode,
                resumeSessionId: resumeSessionId
            )
            // [Fix] The guard-let binding at the top of this function still
            // points at the old (now cancelled) socket — reconnect replaced
            // `self.task`. Re-unwrap the property before retrying, otherwise
            // the retry sends on a cancelled task and always fails.
            guard let replacement = self.task else { throw CCPocketError.notConnected }
            try await replacement.send(.string(string))
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
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
