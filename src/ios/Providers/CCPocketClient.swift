import Foundation

/// WebSocket client for a CC Pocket Bridge Server.
///
/// Owns the connection lifecycle (connect / start / send / receive /
/// reconnect / offline queue) and exposes the server message stream to the
/// provider layer. Design mirrors the official CC Pocket client:
/// - `connect` only announces capabilities; `start` / `resume_session` is a
///   separate step driven by the provider when a turn begins — opening the
///   app never spawns an agent process on its own.
/// - The receive loop auto-reconnects with exponential backoff; app-resume
///   checks call `ensureConnected()` so a socket killed while suspended is
///   revived before the next turn.
/// - Failed sends are queued (memory + UserDefaults) and replayed after a
///   reconnect, so a dead socket never drops a user message.
/// - Session identity comes from the Bridge's `session_list`; a per-instance
///   mapping (bridge session id + claude session id) is persisted so a
///   relaunch resumes the *same* conversation instead of starting a new one.
final class CCPocketClient: @unchecked Sendable {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    enum ClientError: LocalizedError {
        case startTimedOut
        case resumeFailed(String)

        var errorDescription: String? {
            switch self {
            case .startTimedOut: return "Bridge session did not start in time"
            case .resumeFailed(let message): return "Session resume failed: \(message)"
            }
        }
    }

    private(set) var state: State = .idle
    private let logger = AppLogger(category: "CCPocketClient")

    /// Bridge session id (short, 8 chars) — routes `input` (the Bridge
    /// resolves it exactly) and identifies this runtime session.
    private(set) var sessionId: String?

    /// Claude session id (full UUID, 36 chars) — the only id the SDK
    /// `resume` option accepts. Captured from `session_list` / system /
    /// result messages; persisted per instance so a relaunch can resume.
    private(set) var claudeSessionId: String?

    /// True once `start` (or `resume_session`) has been sent on this
    /// connection and a Bridge session id has been captured.
    private(set) var started = false

    private let baseURL: URL
    private let token: String
    private var task: URLSessionWebSocketTask?

    /// Connection parameters retained for auto-reconnect.
    private var projectPath: String?
    private var providerName: String = "claude"
    private var permissionMode: String?

    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pingFailures = 0

    /// Set when the Bridge reports `session_resume_failed`; aborts the
    /// waiting `resumeSession()` caller immediately instead of timing out.
    private var resumeFailure: String?

    /// requestId of our in-flight `start`/`resume_session`. `session_created`
    /// replies carry it; the Bridge broadcasts *all* sessions' system
    /// messages to every client, so only a reply matching our request may
    /// set the routing id.
    private var pendingStartRequestId: String?

    /// Single active consumer of the server message stream. The engine
    /// serialises turns (one turn at a time); a turn ends when the handler
    /// sees a `result` (or error). The provider installs the handler before
    /// sending input so no event is lost in the window.
    var onMessage: ((CCPocketProtocol.ServerMessage) -> Void)?

    /// Messages whose send failed (socket died). Replayed in order after a
    /// successful reconnect so no user message is lost.
    private struct PendingInput: Codable {
        let text: String
        let sessionId: String?
        let clientMessageId: String
        let createdAt: Date
    }
    private var pendingInputs: [PendingInput] = []
    private let pendingLock = NSLock()
    private static let pendingKeyPrefix = "ccpocket.pending.v1."

    /// Per-instance session mapping: bridge id + claude id for this
    /// provider instance. Persisted so a relaunch resumes the same
    /// conversation (and never a stale/dirty id from an earlier version).
    private struct SessionMapping: Codable {
        var bridgeId: String?
        var claudeId: String?
        var projectPath: String?
    }
    private static let mappingKeyPrefix = "ccpocket.sessionMap.v1."

    private static let pingIntervalNanoseconds: UInt64 = 30_000_000_000
    private static let pingMaxFailures = 3
    private static let reconnectBaseDelayNanoseconds: UInt64 = 1_000_000_000
    private static let reconnectMaxDelayNanoseconds: UInt64 = 30_000_000_000

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Connection

    /// Connect to the Bridge and announce capabilities. Does *not* start an
    /// agent session — the provider calls `startSession()` / `resumeSession()`
    /// when a turn begins.
    func connect(projectPath: String, provider: String = "claude", permissionMode: String? = nil) async throws {
        // [Diag]
        logger.info("[CCPocket] connect url=\(baseURL.absoluteString) projectPath=\(projectPath) provider=\(provider) perm=\(permissionMode ?? "default") state=\(state == .idle ? "idle" : "busy")")
        guard state == .idle else {
            logger.warning("[CCPocket] connect skipped — state not idle")
            return
        }

        self.projectPath = projectPath
        self.providerName = provider
        self.permissionMode = permissionMode

        // [Fix] Restore any messages queued by a previous app session so a
        // relaunch does not silently drop them.
        restorePendingInputs()

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

        let capabilities = CCPocketProtocol.ClientCapabilities()
        try await send(CCPocketProtocol.encode(capabilities), allowsReconnect: false)

        startReceiveLoop()
        startPing()
    }

    // MARK: - Session start / resume

    /// True when this connection already carries an active Bridge session.
    var isStarted: Bool { started && sessionId != nil }

    /// Open a brand-new agent session (Bridge spawns a fresh SDK process).
    /// Idempotent; waits for the Bridge session id before returning.
    func startSession() async throws {
        guard !started else { return }
        resumeFailure = nil
        guard let projectPath else { throw CCPocketError.notConnected }
        let requestId = UUID().uuidString
        pendingStartRequestId = requestId
        let start = CCPocketProtocol.StartRequest(
            projectPath: projectPath,
            provider: providerName,
            sessionId: nil,
            continue: nil,
            requestId: requestId,
            permissionMode: permissionMode
        )
        try await send(CCPocketProtocol.encode(start), allowsReconnect: false)
        logger.info("[CCPocket] start sent")
        try await waitForBridgeSessionId()
        started = true
        logger.info("[CCPocket] session started bridgeId=\(sessionId ?? "?")")
    }

    /// Resume a past Claude conversation using the official `resume_session`
    /// message (not `start`): the Bridge restores the conversation and
    /// replies `session_resume_started` (then `system session_created`), or
    /// `session_resume_failed` when the id is unknown / already resuming.
    func resumeSession(claudeId: String) async throws {
        guard !started else { return }
        resumeFailure = nil
        guard let projectPath else { throw CCPocketError.notConnected }
        let resumeRequestId = UUID().uuidString
        pendingStartRequestId = resumeRequestId
        let request = CCPocketProtocol.ResumeSessionRequest(
            sessionId: claudeId,
            projectPath: projectPath,
            provider: providerName,
            permissionMode: permissionMode,
            resumeRequestId: resumeRequestId
        )
        try await send(CCPocketProtocol.encode(request), allowsReconnect: false)
        logger.info("[CCPocket] resume_session sent claudeId=\(claudeId.prefix(8))...")
        try await waitForBridgeSessionId()
        started = true
        logger.info("[CCPocket] session resumed bridgeId=\(sessionId ?? "?")")
    }

    /// Wait (up to 10 s) for the Bridge to hand out the session id after
    /// start/resume. A `session_resume_failed` message aborts immediately.
    private func waitForBridgeSessionId() async throws {
        var waited = 0
        while sessionId == nil && waited < 100 {
            if let resumeFailure {
                logger.error("[CCPocket] resume aborted: \(resumeFailure)")
                throw ClientError.resumeFailed(resumeFailure)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        guard sessionId != nil else {
            logger.error("[CCPocket] no bridge session id after \(waited * 100)ms")
            throw ClientError.startTimedOut
        }
        logger.info("[CCPocket] bridge session id captured after \(waited * 100)ms")
    }

    // MARK: - Sending

    func sendInput(_ text: String, sessionId: String? = nil) async throws {
        // [Fix] Replay anything queued from an earlier dead socket first
        // (only when no turn is in flight — replaying mid-turn would make
        // the Bridge interrupt the running turn).
        if !pendingInputs.isEmpty, !hasActiveTurn, isStarted {
            flushPendingInputs()
        }
        let clientMessageId = UUID().uuidString
        let input = CCPocketProtocol.InputRequest(
            text: text,
            sessionId: sessionId,
            clientMessageId: clientMessageId
        )
        do {
            // [Fix] allowsReconnect: false — `send`'s retry would re-send the
            // old encoded payload whose baked-in sessionId is dead after a
            // reconnect. Fail fast; the offline queue replays with a fresh
            // encoding once reconnected.
            try await send(CCPocketProtocol.encode(input), allowsReconnect: false)
        } catch {
            // Socket died underneath us — queue the message; the reconnect
            // flow replays it so the user's message is never lost.
            logger.warning("[CCPocket] sendInput failed, queuing (\(error.localizedDescription))")
            enqueuePending(PendingInput(text: text, sessionId: sessionId, clientMessageId: clientMessageId, createdAt: Date.now))
            throw error
        }
    }

    private func send(_ string: String, allowsReconnect: Bool = true) async throws {
        guard let task else { throw CCPocketError.notConnected }
        do {
            try await task.send(.string(string))
        } catch {
            logger.warning("[CCPocket] send failed (\(error.localizedDescription)) — reconnecting and retrying once")
            disconnect()
            guard allowsReconnect, let projectPath else {
                throw error
            }
            try await reconnectNow()
            guard let replacement = self.task else { throw CCPocketError.notConnected }
            try await replacement.send(.string(string))
        }
    }

    /// Stop the current turn; the Bridge answers with `result subtype=stopped`.
    func interrupt() async {
        guard let sessionId else { return }
        let request = CCPocketProtocol.InterruptRequest(sessionId: sessionId)
        try? await send(CCPocketProtocol.encode(request))
    }

    /// True while a turn's stream handler is installed (a turn is in flight).
    private var hasActiveTurn: Bool { onMessage != nil }

    // MARK: - Reconnect

    /// App returned to foreground: if the socket died while suspended
    /// (receive loop exited, state != connected) reconnect immediately.
    func ensureConnected() {
        guard state != .connected, state != .connecting else { return }
        guard reconnectTask == nil else { return }
        logger.info("[CCPocket] ensureConnected — reconnecting (state=\(String(describing: state)))")
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await self.reconnectNow()
            self.reconnectTask = nil
        }
    }

    /// Re-establish the socket and, if a session was started on this
    /// connection, resume/restart it, then replay queued messages.
    private func reconnectNow() async throws {
        logger.info("[CCPocket] reconnectNow start (was started=\(started))")
        guard let projectPath else { throw CCPocketError.notConnected }
        // Capture before disconnect (disconnect clears them).
        let resumeClaudeId = claudeSessionId
        let wasStarted = started
        // [Fix] Reset state first: the receive loop may have left us in
        // `.failed`, which `connect`'s `guard state == .idle` would reject.
        disconnect()
        try await connect(
            projectPath: projectPath,
            provider: providerName,
            permissionMode: permissionMode
        )
        if wasStarted {
            if let resumeClaudeId {
                try? await resumeSession(claudeId: resumeClaudeId)
            }
            if !isStarted {
                try? await startSession()
            }
        }
        // [Fix] A successful reconnect resets the backoff so a later blip
        // retries fast instead of starting at the 30s cap.
        reconnectDelay = Self.reconnectBaseDelayNanoseconds
        flushPendingInputs()
        logger.info("[CCPocket] reconnectNow done (started=\(started))")
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        // Exponential backoff 1s → 2s → ... → 30s cap.
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.reconnectMaxDelayNanoseconds)
        logger.info("[CCPocket] scheduling reconnect in \(delay / 1_000_000_000)s")
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            try? await self.reconnectNow()
            self.reconnectTask = nil
        }
    }
    private var reconnectDelay: UInt64 = CCPocketClient.reconnectBaseDelayNanoseconds

    // MARK: - Receive loop

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
                            self.handleIncoming(serverMessage)
                        }
                    case .data(let data):
                        if let serverMessage = CCPocketProtocol.decodeServerMessage(data) {
                            self.handleIncoming(serverMessage)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    // [Fix] A cancelled receive (we disconnected on purpose)
                    // must NOT trigger a reconnect — that caused reconnect
                    // storms where each cycle killed the previous healthy
                    // connection.
                    if Task.isCancelled { return }
                    self.state = .failed(error.localizedDescription)
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    private func handleIncoming(_ message: CCPocketProtocol.ServerMessage) {
        captureSession(from: message)

        // [Fix] Resume failure arrives as `system` + subtype (verified
        // against Bridge source); it aborts the waiting `resumeSession()`
        // caller immediately instead of timing out.
        if message.type == "system", message.subtype == "session_resume_failed" {
            resumeFailure = message.error ?? "session resume rejected by Bridge"
            logger.error("[CCPocket] session_resume_failed: \(resumeFailure ?? "?")")
            return
        }

        // Input acknowledgement — acked messages can leave the queue.
        if message.type == "input_ack",
           let clientMessageId = message.clientMessageId {
            removePending(clientMessageId: clientMessageId)
        }

        onMessage?(message)
    }

    /// Capture the Bridge session id and the Claude session id from incoming
    /// messages. Runs on every message so ids are captured even when no
    /// per-turn handler is installed yet.
    /// [Fix] Two separate ids are tracked: `sessionId` (8 chars) routes
    /// `input`; `claudeSessionId` (36 chars) is the SDK resume target. It
    /// arrives via an explicit `claudeSessionId` field, a long `sessionId`
    /// on system/result messages, or the `session_list` payload (sent on
    /// every connection) — the reliable source even before any `result`.
    private func captureSession(from message: CCPocketProtocol.ServerMessage) {
        // [Fix] The Bridge broadcasts every session's system messages to all
        // clients (verified against Bridge source). Only a `session_created`
        // reply carrying OUR start/resume request id may set the routing id —
        // otherwise another client's session activity would overwrite ours
        // (sending-side cross-session bleed).
        if message.type == "system" {
            if message.subtype == "session_created" {
                let isOurs = message.requestId == pendingStartRequestId
                    || message.resumeRequestId == pendingStartRequestId
                if isOurs, let raw = message.sessionId, raw.count <= 8, raw != sessionId {
                    sessionId = raw
                    logger.info("[CCPocket] captured bridgeSessionId=\(raw) (session_created)")
                } else if !isOurs {
                    logger.info("[CCPocket] session_created for another request — ignored")
                }
            } else if message.subtype == "session_resume_started" {
                // Resume is in flight; the session_created reply follows.
                logger.info("[CCPocket] session_resume_started (waiting for session_created)")
            }
        }
        // Claude id capture is also scoped to our session: broadcast messages
        // carry the (short) routing id of their own session, so only messages
        // without an id or matching ours are considered. Before the session
        // exists (sessionId == nil, start/resume in flight) nothing may set
        // the claude id — otherwise another client's broadcast could poison
        // our resume mapping.
        let belongsToUs: Bool
        if let sessionId {
            belongsToUs = message.sessionId == nil || message.sessionId == sessionId
        } else {
            belongsToUs = false
        }
        let claudeId: String?
        if belongsToUs, let explicit = message.claudeSessionId {
            claudeId = explicit
        } else if belongsToUs, let raw = message.sessionId, raw.count > 8 {
            claudeId = raw
        } else {
            claudeId = nil
        }
        if let claudeId, claudeId != claudeSessionId {
            claudeSessionId = claudeId
            logger.info("[CCPocket] captured claudeSessionId=\(claudeId.prefix(8))... msg=\(message.type ?? "?")")
        }
        // `session_list` carries the authoritative claudeSessionId per
        // Bridge session — match by our Bridge session id.
        // [Style] Two-step binding (no guard/if-let chain with a trailing
        // closure) per project Swift rules.
        if let sessions = message.sessions, let sessionId {
            let match = sessions.first { $0.id == sessionId }
            if let claudeId = match?.claudeSessionId, claudeId != claudeSessionId {
                claudeSessionId = claudeId
                logger.info("[CCPocket] captured claudeSessionId from session_list=\(claudeId.prefix(8))...")
            }
        }
    }

    // MARK: - Ping

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalNanoseconds)
                guard !Task.isCancelled else { break }
                self.task?.sendPing { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.pingFailures += 1
                        self.logger.warning("[CCPocket] ping failed (\(error.localizedDescription)) failures=\(self.pingFailures)")
                        if self.pingFailures >= Self.pingMaxFailures {
                            // Socket is dead but the receive loop may never
                            // notice (suspended process) — force reconnect.
                            self.pingFailures = 0
                            self.logger.warning("[CCPocket] ping threshold reached — forcing reconnect")
                            Task { [weak self] in
                                guard let self else { return }
                                self.disconnect()
                                self.scheduleReconnect()
                            }
                        }
                    } else {
                        self.pingFailures = 0
                    }
                }
            }
        }
    }

    // MARK: - Offline queue

    private func enqueuePending(_ input: PendingInput) {
        pendingLock.lock()
        pendingInputs.append(input)
        pendingLock.unlock()
        persistPendingInputs()
    }

    private func removePending(clientMessageId: String) {
        pendingLock.lock()
        pendingInputs.removeAll { $0.clientMessageId == clientMessageId }
        pendingLock.unlock()
        persistPendingInputs()
    }

    private func persistPendingInputs() {
        guard let projectPath else { return }
        let key = Self.pendingKeyPrefix + projectPath
        pendingLock.lock()
        let snapshot = pendingInputs
        pendingLock.unlock()
        if snapshot.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func restorePendingInputs() {
        guard let projectPath else { return }
        let key = Self.pendingKeyPrefix + projectPath
        guard let data = UserDefaults.standard.data(forKey: key),
              let inputs = try? JSONDecoder().decode([PendingInput].self, from: data) else { return }
        pendingLock.lock()
        pendingInputs = inputs
        pendingLock.unlock()
    }

    /// Replay queued messages in order after a successful reconnect.
    /// [Fix] Never replay while a turn is in flight: the Bridge would queue
    /// the replayed input and interrupt the running turn.
    private func flushPendingInputs() {
        guard !pendingInputs.isEmpty, isStarted, !hasActiveTurn else { return }
        logger.info("[CCPocket] replaying \(pendingInputs.count) queued message(s)")
        pendingLock.lock()
        let queued = pendingInputs
        pendingInputs.removeAll()
        pendingLock.unlock()
        persistPendingInputs()
        for input in queued {
            let message = CCPocketProtocol.InputRequest(
                text: input.text,
                sessionId: input.sessionId ?? sessionId,
                clientMessageId: input.clientMessageId
            )
            // Fire-and-forget within the reconnect flow; failures re-queue
            // so a message is never dropped.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.send(CCPocketProtocol.encode(message))
                } catch {
                    self.enqueuePending(input)
                }
            }
        }
    }

    // MARK: - Session mapping persistence

    /// Persist this instance's session identity (bridge id + claude id) so a
    /// relaunch resumes the same conversation. `claudeId` is the resume key;
    /// a stale short value (8-char bridge id written by M1) is dropped.
    func saveMapping(instanceID: String) {
        guard let claudeSessionId, claudeSessionId.count > 8 else { return }
        let mapping = SessionMapping(
            bridgeId: sessionId,
            claudeId: claudeSessionId,
            projectPath: projectPath
        )
        let key = Self.mappingKeyPrefix + instanceID
        if let data = try? JSONEncoder().encode(mapping) {
            UserDefaults.standard.set(data, forKey: key)
            logger.info("[CCPocket] saved session mapping instance=\(instanceID.prefix(8)) claude=\(claudeSessionId.prefix(8))...")
        }
    }

    /// Previously saved session identity for this instance, if usable.
    func loadMapping(instanceID: String) -> (bridgeId: String?, claudeId: String?, projectPath: String?)? {
        let key = Self.mappingKeyPrefix + instanceID
        guard let data = UserDefaults.standard.data(forKey: key),
              let mapping = try? JSONDecoder().decode(SessionMapping.self, from: data) else { return nil }
        // A short claudeId is a stale M1 bridge id — useless (and harmful)
        // for resume; drop it.
        guard let claudeId = mapping.claudeId, claudeId.count > 8 else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return (mapping.bridgeId, claudeId, mapping.projectPath)
    }

    // MARK: - Teardown

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // [Fix] Deliberately keep `onMessage`: a mid-turn reconnect must not
        // drop the stream handler (the turn's `result` would be lost and the
        // stream would hang). The provider clears it when the turn finishes.
        started = false
        sessionId = nil
        resumeFailure = nil
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
