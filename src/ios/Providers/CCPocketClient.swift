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

    private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            // [Connection dot] Push every state flip to the sidebar's
            // connection indicator (recomputed on the main actor).
            Task { @MainActor in
                ConnectionStatusStore.shared.recompute()
            }
        }
    }
    private let logger = AppLogger(category: "CCPocketClient")

    /// Provider-instance id this client belongs to. Set by the factory;
    /// used to persist the session mapping immediately when the Claude id
    /// is captured (not only at turn end), so a kill right after the first
    /// message still resumes the same conversation next launch.
    var mappingInstanceID: String?

    /// [Per-session mapping] Chat session (claudio conversation) this
    /// connection is bound to. Set by the provider once the Bridge session
    /// is started/resumed/reused for a turn. The factory only reuses a
    /// connection whose binding matches — every chat conversation owns its
    /// Bridge session (official: ChatSessionCubit holds `final sessionId`,
    /// input carries it, messages route per session).
    var boundChatSessionID: String?

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
    /// [Fix] Monotonic counter incremented on every `connect()`. Captured by
    /// the receive loop at task start; any incoming message whose `taskEpoch`
    /// doesn't match the current `connectionEpoch` is dropped silently.
    /// Mirrors ccpocket official mobile's `_connectionEpoch` (apps/mobile/lib/
    /// services/bridge_service.dart:273) — without this, an in-flight
    /// `assistant/1blocks` from a stale `URLSessionWebSocketTask` resumes
    /// after a reconnect and is dispatched to `onMessage` a second time,
    /// producing duplicate assistant replies in the UI.
    /// [C-ios-remote-agent-duplicate-reply] (2026-09-04) — bug observed on
    /// session 16BAD1FB (turn 5, 13-second foreground/background storm).
    private var connectionEpoch: Int = 0

    /// Set when the Bridge reports `session_resume_failed`; aborts the
    /// waiting `resumeSession()` caller immediately instead of timing out.
    private var resumeFailure: String?

    /// requestId of our in-flight `start`/`resume_session`. `session_created`
    /// replies carry it; the Bridge broadcasts *all* sessions' system
    /// messages to every client, so only a reply matching our request may
    /// set the routing id.
    private var pendingStartRequestId: String?

    /// Set when the Bridge accepts our `resume_session`
    /// (`system session_resume_started`). Resuming a large conversation can
    /// take much longer than a fresh start — once accepted, wait longer
    /// instead of timing out and racing a fallback `start`.
    private var resumeAccepted = false

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
        /// 离线队列重放时带上的图片 base64 数组（png/jpeg/gif/webp 内联）。
        var images: [[String: String]]?
    }
    private var pendingInputs: [PendingInput] = []
    private let pendingLock = NSLock()

    /// RPC continuation 等 file_upload_ready/error/complete 等 RPC 响应。
    /// 按 requestId 关联；WS 接收循环在 decode 前拦截匹配的 requestId。
    private var rpcWaiters: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private let rpcLock = NSLock()
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

    /// Serialises reconnect attempts. `ensureConnected` (foreground return)
    /// and `scheduleReconnect` (ping/receive failure) can fire concurrently;
    /// without the lock one blip caused two parallel reconnectNow runs, each
    /// re-spawning a Bridge session (process pile-up).
    private let reconnectLock = NSLock()

    /// [A-plan v1] Pending continuation for a `get_history` reply
    /// (`history_snapshot` / `history_delta`). One fetch at a time; the
    /// reply resumes the waiter and is NOT forwarded to `onMessage` (a
    /// history fetch runs outside any turn — the turn-scoped consumer must
    /// never see replay traffic).
    /// Collected history messages (history + past_history merged).
    private var historyMessages: [CCPocketProtocol.ServerMessage] = []
    private var historyWaiter: CheckedContinuation<[CCPocketProtocol.ServerMessage], Never>?

    /// [Session sync] Pending continuation for a `recent_sessions` reply
    /// (mirror of the history waiter — request/response, never broadcast).
    /// Returns the whole message so the caller can read hasMore for paging.
    private var recentWaiter: CheckedContinuation<CCPocketProtocol.ServerMessage?, Never>?

    /// Last `session_list` payload from the Bridge (sent on every
    /// connection). Used for cold-start reuse: our persisted bridge session
    /// id is present in this list iff its SDK process is still resident on
    /// the Bridge, so input can route to it without resuming (no new
    /// runtime session in the official client's running list).
    private var knownBridgeSessions: [CCPocketProtocol.ServerSession]?

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Connection

    /// Connect to the Bridge and announce capabilities. Does *not* start an
    /// agent session — the provider calls `startSession()` / `resumeSession()`
    /// when a turn begins.
    func connect(projectPath: String, provider: String = "claude", permissionMode: String? = nil) async throws {
        // [Fix] Bump epoch so any in-flight receive tasks that haven't yet
        // seen their taskEpoch != connectionEpoch check (still inside an
        // `await task?.receive()` suspension) drop the next message they
        // observe. Captured below in startReceiveLoop into a task-local
        // immutable so the comparison is stable across that task's lifetime.
        connectionEpoch += 1
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
        resumeAccepted = false
        guard let projectPath else { throw CCPocketError.notConnected }
        let requestId = UUID().uuidString
        pendingStartRequestId = requestId
        // [New-session sheet] Fill the full option set from the persisted
        // defaults (official _startNewSession semantics: the sheet saves
        // after each start, the provider reads them at the next start).
        let defaults = RemoteSessionDefaultsStore.load()
        let start = CCPocketProtocol.StartRequest(
            projectPath: projectPath,
            provider: providerName,
            sessionId: nil,
            continue: nil,
            requestId: requestId,
            model: defaults.model,
            permissionMode: permissionMode ?? defaults.permissionMode,
            executionMode: defaults.executionMode == "default" ? nil : defaults.executionMode,
            planMode: defaults.planMode ? true : nil,
            effort: defaults.effort,
            fallbackModel: defaults.fallbackModel,
            forkSession: defaults.forkSession ? true : nil,
            persistSession: defaults.persistSession ? true : nil
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
        resumeAccepted = false
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

    /// Wait (up to 10 s, 30 s once the Bridge accepted a resume) for the
    /// session id after start/resume. A `session_resume_failed` aborts
    /// immediately.
    /// [Fix] Resuming a large conversation can exceed 10 s; timing out there
    /// raced a fallback `start` against the still-running resume, which
    /// created a second session on the Bridge (visible as a new conversation
    /// in the official client). Once `session_resume_started` arrives the
    /// resume is in flight — keep waiting.
    private func waitForBridgeSessionId() async throws {
        let limit = resumeAccepted ? 300 : 100
        var waited = 0
        while sessionId == nil && waited < limit {
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

    func sendInput(_ text: String, sessionId: String? = nil, images: [[String: String]]? = nil) async throws {
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
            clientMessageId: clientMessageId,
            images: images
        )
        do {
            try await send(CCPocketProtocol.encode(input), allowsReconnect: false)
        } catch {
            logger.warning("[CCPocket] sendInput failed, queuing (\(error.localizedDescription))")
            enqueuePending(PendingInput(text: text, sessionId: sessionId, clientMessageId: clientMessageId, createdAt: Date.now, images: images))
            throw error
        }
    }

    /// 发一个 RPC 请求（带 requestId）并等待对应响应。
    /// 用于 prepare_file_upload / finalize_file_upload 等请求-响应消息。
    /// 返回原始 JSON dict（含 uploadUrl/uploadToken/errorCode 等字段）。
    func sendAndWaitRPC(_ payload: [String: Any]) async throws -> [String: Any] {
        let requestId = (payload["requestId"] as? String) ?? UUID().uuidString
        var req = payload
        req["requestId"] = requestId
        let json = try JSONSerialization.data(withJSONObject: req)
        let str = String(data: json, encoding: .utf8) ?? "{}"
        return try await withCheckedThrowingContinuation { cont in
            rpcLock.lock()
            rpcWaiters[requestId] = cont
            rpcLock.unlock()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.send(str, allowsReconnect: false)
                } catch {
                    self.rpcLock.lock()
                    self.rpcWaiters.removeValue(forKey: requestId)
                    self.rpcLock.unlock()
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func send(_ string: String, allowsReconnect: Bool = true) async throws {
        guard let task else { throw CCPocketError.notConnected }
        do {
            try await task.send(.string(string))
        } catch {
            logger.warning("[CCPocket] send failed (\(error.localizedDescription)) — reconnecting and retrying once")
            // [Fix] Soft teardown only: the Bridge session (and its agent
            // process) survives on the server, so the retry must route
            // through the same session id — hard-disconnecting cleared it
            // and forced a resume (new SDK process) per reconnect.
            teardownSocket()
            guard allowsReconnect else {
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

    /// [Stop-session] Ask the Bridge to destroy a runtime session (official
    /// stop_session, websocket.ts:4751). Disk history is not touched; the
    /// per-chat mapping stays so the next load resumes the same Claude
    /// conversation (the reuse probe fails on the dead bridge id and falls
    /// back to resume — both paths already in place).
    // MARK: - [Remote session options] Mid-session switches

    /// Bridge `set_permission_mode` — live permission-mode switch for the
    /// current session. Requires a started session; callers fall back to
    /// the start defaults when the session has not begun.
    func setPermissionMode(_ mode: String) async throws {
        guard isStarted, let bridgeId = sessionId else {
            throw CCPocketError.sessionNotStarted
        }
        let req = CCPocketProtocol.SetPermissionModeRequest(mode: mode, sessionId: bridgeId)
        try await sendEncoded(req)
    }

    /// Bridge `set_sandbox_mode` — live sandbox switch (see setPermissionMode).
    func setSandboxMode(_ mode: String) async throws {
        guard isStarted, let bridgeId = sessionId else {
            throw CCPocketError.sessionNotStarted
        }
        let req = CCPocketProtocol.SetSandboxModeRequest(sandboxMode: mode, sessionId: bridgeId)
        try await sendEncoded(req)
    }

    private func sendEncoded<T: Encodable>(_ req: T) async throws {
        // Encode failure is practically impossible for these flat structs;
        // the session guard above is the real gate.
        guard let payload = try? CCPocketProtocol.encode(req) else {
            throw CCPocketError.sessionNotStarted
        }
        try await send(payload, allowsReconnect: true)
    }

    func sendStopSession(bridgeId: String) async {
        guard state == .connected else { return }
        let request = CCPocketProtocol.StopSessionRequest(sessionId: bridgeId)
        try? await send(CCPocketProtocol.encode(request))
    }

    /// [M3] Answer a `permission_request` (official ClientMessage.approve /
    /// approveAlways / reject / answer — messages.dart:4591). `kind` is the
    /// wire type; `id` is the toolUseId from the request.
    func sendPermissionResponse(kind: String, id: String, clearContext: Bool = false, message: String? = nil, answer: String? = nil) async {
        guard state == .connected else { return }
        let request = CCPocketProtocol.PermissionResponseRequest(
            type: kind,
            id: id,
            sessionId: sessionId,
            clearContext: clearContext ? true : nil,
            message: message,
            toolUseId: kind == "answer" ? id : nil,
            result: answer
        )
        try? await send(CCPocketProtocol.encode(request))
    }

    // MARK: - Reconnect

    /// App returned to foreground: if the socket died while suspended
    /// (receive loop exited, state != connected) reconnect immediately.
    /// [A-plan v1] Request a full history replay for the Bridge session that
    /// hosts `claudeId`. Resolves the Bridge session id from the persisted
    /// mapping first (survives relaunch), falling back to the latest
    /// `session_list` payload. Returns the replayed wire messages in seq
    /// order, or nil on timeout / unknown session (caller falls back to the
    /// local cache — offline semantics match the official client).
    func requestHistory(claudeId: String, timeout: TimeInterval = 15) async -> [CCPocketProtocol.ServerMessage]? {
        // Resolve Bridge session id: mapping first, then session_list.
        var bridgeId = loadMapping(instanceID: mappingInstanceID ?? "", chatSessionID: boundChatSessionID)?.bridgeId
        if bridgeId == nil || bridgeId?.isEmpty == true {
            for _ in 0..<12 {
                bridgeId = knownBridgeSessions?.first { $0.claudeSessionId == claudeId }?.id
                if bridgeId != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // [Session sync] Recent-index sessions are NOT live — their bridge id
        // is in neither the mapping nor the broadcast. Resume spawns the
        // runtime process (official recent-session open semantics) and
        // yields the bridge id the history fetch needs.
        if bridgeId == nil || bridgeId?.isEmpty == true {
            do {
                try await resumeSession(claudeId: claudeId)
                bridgeId = sessionId
                logger.info("[CCPocket] history: resume fallback spawned bridge session \(sessionId?.prefix(8) ?? "?")")
            } catch {
                logger.warning("[CCPocket] history: resume fallback failed \(error.localizedDescription)")
            }
        }
        guard let bridgeId, !bridgeId.isEmpty else {
            logger.warning("[CCPocket] history: no Bridge session id for claude \(claudeId.prefix(8))...")
            return nil
        }
        let req = CCPocketProtocol.GetHistoryRequest(sessionId: bridgeId)
        guard let payload = try? CCPocketProtocol.encode(req) else { return nil }
        do {
            try await send(payload, allowsReconnect: false)
        } catch {
            logger.warning("[CCPocket] history: send failed \(error.localizedDescription)")
            return nil
        }
        // Await the reply.  The dispatcher only resumes the continuation
        // once — when `history` (new bridge: comes last after past_history)
        // or `history_snapshot` (old bridge: only message) arrives.  The
        // payload delivered is historyMessages + [final], i.e. ALL replies.
        // On timeout we still have whatever the accumulator caught.
        historyMessages = []
        let result: [CCPocketProtocol.ServerMessage] = await withCheckedContinuation { c in
            historyWaiter = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                if let w = self.historyWaiter {
                    self.historyWaiter = nil
                    w.resume(returning: self.historyMessages)
                }
            }
        }
        guard !result.isEmpty else {
            logger.warning("[CCPocket] history: timeout after \(timeout)s")
            return nil
        }
        // Build flat [ServerMessage] from both the flat form (history with
        // messages[]) AND the old entries form (history_snapshot/delta).
        var flat: [CCPocketProtocol.ServerMessage] = []
        for msg in result {
            if let msgs = msg.messages { flat.append(contentsOf: msgs) }
            if let past = msg.pastMessages { flat.append(contentsOf: past) }
            if let entries = msg.entries { flat.append(contentsOf: entries.compactMap { $0.message }) }
        }
        // De-duplicate: same message may appear in both past_history and
        // history on a fresh session (bridge sends all messages in history,
        // pastMessages=[]).  Also dedupe across entries duplicates.
        var seen = Set<String>()
        var unique: [CCPocketProtocol.ServerMessage] = []
        for m in flat {
            // Dedup key: ServerMessage.sessionId is the bridge session id,
            // present on all reply wrappers.  Deeper message-level id is not
            // available without a switch on MessagePayload (enum with no
            // sessionId property), and the top-level id is sufficient for
            // the past_history+history overlap case we hit in practice.
            let key = m.sessionId ?? ""
            if !key.isEmpty && seen.contains(key) { continue }
            if !key.isEmpty { seen.insert(key) }
            unique.append(m)
        }
        if unique.isEmpty {
            logger.info("[CCPocket] history: empty reply (all forms empty)")
            return nil
        }
        logger.info("[CCPocket] history: \(unique.count) messages from bridge (raw=\(result.count) msgs)")
        return unique
    }

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

    /// Re-establish the socket only, then replay queued messages.
    /// [Fix] Aligned with the official client (bridge_service.dart): a
    /// reconnect NEVER re-runs `start`/`resume_session` — the Bridge keeps
    /// the agent process alive for idle sessions, and `input` routed to the
    /// original bridge session id reaches it again. Re-running resume here
    /// made the Bridge spawn a fresh SDK process per reconnect (process
    /// pile-up + a new session record per turn in the official client).
    /// Resume happens only on a cold start, in RemoteAgentProvider's first
    /// turn (ensureSessionStarted).
    private func reconnectNow() async throws {
        guard reconnectLock.try() else {
            logger.info("[CCPocket] reconnectNow skipped — another reconnect in flight")
            return
        }
        defer { reconnectLock.unlock() }
        logger.info("[CCPocket] reconnectNow start (was started=\(started))")
        guard let projectPath else { throw CCPocketError.notConnected }
        // Soft teardown: keep started/sessionId/claudeSessionId so queued
        // messages replay through the existing Bridge session.
        teardownSocket()
        try await connect(
            projectPath: projectPath,
            provider: providerName,
            permissionMode: permissionMode
        )
        // No resume/start here — the session survived on the Bridge.
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
        // [Fix] Capture the current epoch into a local. Any message received
        // after this task started but where connectionEpoch has since moved
        // forward (i.e. another connect() call bumped it) is a stale-frame
        // delivery from the old socket — drop it without dispatching to
        // `onMessage`, preventing duplicate assistant replies in the UI.
        // Mirrors ccpocket official mobile's `_connectionEpoch` (apps/mobile/
        // lib/services/bridge_service.dart:273). See connectionEpoch doc.
        let taskEpoch = connectionEpoch
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await self.task?.receive()
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            // RPC 响应拦截：有 requestId 且在 rpcWaiters 里 → resume + 跳过 handleIncoming
                            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let reqId = json["requestId"] as? String {
                                self.rpcLock.lock()
                                let waiter = self.rpcWaiters.removeValue(forKey: reqId)
                                self.rpcLock.unlock()
                                if let waiter {
                                    if json["type"] as? String == "error" {
                                        let code = (json["errorCode"] as? String) ?? "rpc_error"
                                        let msg = (json["message"] as? String) ?? "RPC error"
                                        waiter.resume(throwing: RemoteUploadError(code: code, message: msg))
                                    } else {
                                        waiter.resume(returning: json)
                                    }
                                    continue
                                }
                            }
                            if let serverMessage = CCPocketProtocol.decodeServerMessage(data) {
                                // [Fix] Drop stale-frame messages (see taskEpoch comment)
                                if taskEpoch != self.connectionEpoch {
                                    logger.info("[CCPocket] dropping stale frame (taskEpoch=\(taskEpoch) current=\(self.connectionEpoch)) type=\(serverMessage.type ?? "?")")
                                } else {
                                    self.handleIncoming(serverMessage)
                                }
                            }
                        }
                    case .data(let data):
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let reqId = json["requestId"] as? String {
                            self.rpcLock.lock()
                            let waiter = self.rpcWaiters.removeValue(forKey: reqId)
                            self.rpcLock.unlock()
                            if let waiter {
                                if json["type"] as? String == "error" {
                                    let code = (json["errorCode"] as? String) ?? "rpc_error"
                                    let msg = (json["message"] as? String) ?? "RPC error"
                                    waiter.resume(throwing: RemoteUploadError(code: code, message: msg))
                                } else {
                                    waiter.resume(returning: json)
                                }
                                continue
                            }
                        }
                        if let serverMessage = CCPocketProtocol.decodeServerMessage(data) {
                            // [Fix] Drop stale-frame messages (see taskEpoch comment)
                                if taskEpoch != self.connectionEpoch {
                                    logger.info("[CCPocket] dropping stale frame (taskEpoch=\(taskEpoch) current=\(self.connectionEpoch)) type=\(serverMessage.type ?? "?")")
                                } else {
                                    self.handleIncoming(serverMessage)
                                }
                        }
                    case .none:
                        break
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

        // [A-plan v1] History replay reply — resume the fetch waiter.
        // Bridge sends TWO sequential messages: past_history (disk history
        // from resume), then history (in-memory since session start).
        // Old Codex bridge sends history_snapshot / history_delta instead.
        // All four types feed into the same collector in requestHistory.
        // Resume-once contract: only `history` (new bridge, LAST) and
        // `history_snapshot` (old Codex bridge, SOLE) resume.  past_history
        // and history_delta accumulate into historyMessages.
        if message.type == "history" || message.type == "history_snapshot" {
            if let w = historyWaiter {
                historyWaiter = nil
                w.resume(returning: historyMessages + [message])
            }
            historyMessages = []
            return
        }
        if message.type == "past_history" || message.type == "history_delta" {
            historyMessages.append(message)
            return
        }

        // [Session sync] `recent_sessions` reply — resume the inventory
        // waiter (mirror of the history fetch pattern; never broadcast).
        if message.type == "recent_sessions" {
            if let w = recentWaiter {
                recentWaiter = nil
                w.resume(returning: message)
            }
            return
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
                // Mark accepted so waitForBridgeSessionId extends its window.
                resumeAccepted = true
                logger.info("[CCPocket] session_resume_started (waiting for session_created)")
            } else if message.subtype == "supported_commands" {
                // 远端技能（服务器 Claude Code）— 与本地 SkillStore 隔离。
                // SDK 会话进程启动时推一次；按 bridge 实例缓存，冷启动可见。
                if let instanceID = mappingInstanceID {
                    let remoteSkills = RemoteSkillRegistry.parse(message: message)
                    Task { @MainActor in
                        RemoteSkillRegistry.shared.update(instanceID: instanceID, skills: remoteSkills)
                    }
                }
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
            // [Fix] Persist the mapping the moment the Claude id is known —
            // waiting for turn end lost it when the app was killed right
            // after the first message (next launch started a brand-new
            // conversation → the official client showed a new session per
            // reply).
            if let mappingInstanceID {
                saveMapping(instanceID: mappingInstanceID, chatSessionID: boundChatSessionID)
            }
        }
        // `session_list` carries the authoritative claudeSessionId per
        // Bridge session — match by our Bridge session id.
        // [Style] Two-step binding (no guard/if-let chain with a trailing
        // closure) per project Swift rules.
        if let sessions = message.sessions {
            knownBridgeSessions = sessions
            // [Session sync] Full live entries → registry inventory so the
            // sidebar can merge remote-only rows (broadcast is idempotent).
            if let instanceID = mappingInstanceID {
                let entries = sessions.compactMap { Self.remoteInventoryEntry(from: $0, isLive: true) }
                Task { @MainActor in
                    BridgeSessionRegistry.shared.setLive(instanceID: instanceID, entries: entries)
                }
            }
            // [Running dot] The Bridge broadcasts the same global
            // session_list to every connection; surface it to the sidebar
            // registry so remote rows can draw their green/grey dot.
            if let mappingInstanceID {
                let instanceID = mappingInstanceID
                Task { @MainActor in
                    BridgeSessionRegistry.shared.update(instanceID: instanceID, sessions: sessions)
                }
            }
            if let sessionId {
                let match = sessions.first { $0.id == sessionId }
                if let claudeId = match?.claudeSessionId, claudeId != claudeSessionId {
                    claudeSessionId = claudeId
                    logger.info("[CCPocket] captured claudeSessionId from session_list=\(claudeId.prefix(8))...")
                }
            }
        }
        // [Model catalog] session_list 还携带 7 个远端模型字段
        // (claudeModels / claudeModelEfforts / codexModels / ...);
        // 每条 broadcast 都推,直接喂给 RemoteModelCatalog 刷新 UI。
        // 桥空广播时(nil/空)Catalog 内部按"保留上次值"语义处理。
        if let instanceID = mappingInstanceID {
            let iid = instanceID
            Task { @MainActor in
                RemoteModelCatalog.shared.apply(
                    instanceID: iid,
                    claudeModels: message.claudeModels,
                    claudeModelEfforts: message.claudeModelEfforts,
                    codexModels: message.codexModels,
                    codexModelReasoningEfforts: message.codexModelReasoningEfforts,
                    codexModelServiceTiers: message.codexModelServiceTiers,
                    codexProfiles: message.codexProfiles,
                    defaultCodexProfile: message.defaultCodexProfile
                )
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
                                self.teardownSocket()
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
                clientMessageId: input.clientMessageId,
                images: input.images
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
    /// Persist this chat conversation's session identity (bridge id +
    /// claude id) so a relaunch resumes the same conversation. Keyed per
    /// chat session; a detached client (title generation etc., chatSessionID
    /// == nil) owns no conversation and must never persist an identity.
    /// `claudeId` is the resume key; a stale short value (8-char bridge id
    /// written by M1) is dropped.
    func saveMapping(instanceID: String, chatSessionID: String?) {
        guard let chatSessionID else { return }
        guard let claudeSessionId, claudeSessionId.count > 8 else { return }
        let mapping = SessionMapping(
            bridgeId: sessionId,
            claudeId: claudeSessionId,
            projectPath: projectPath
        )
        let key = Self.mappingKeyPrefix + instanceID + "." + chatSessionID
        if let data = try? JSONEncoder().encode(mapping) {
            UserDefaults.standard.set(data, forKey: key)
            logger.info("[CCPocket] saved session mapping instance=\(instanceID.prefix(8)) chat=\(chatSessionID.prefix(8)) claude=\(claudeSessionId.prefix(8))...")
        }
    }

    /// Decode + validate a stored mapping. A short claudeId is a stale M1
    /// bridge id — useless (and harmful) for resume; drop it.
    private static func decodeMapping(key: String) -> (bridgeId: String?, claudeId: String?, projectPath: String?)? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let mapping = try? JSONDecoder().decode(SessionMapping.self, from: data) else { return nil }
        guard let claudeId = mapping.claudeId, claudeId.count > 8 else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return (mapping.bridgeId, claudeId, mapping.projectPath)
    }

    /// Previously saved session identity for this chat conversation, if
    /// usable. Detached clients (chatSessionID == nil) never see one.
    /// Legacy migration: pre-per-session builds stored one identity per
    /// provider instance; only the explicit load path opts in
    /// (`allowLegacyFallback`) — a brand-new draft session must never claim
    /// it (that was the cross-session bleed bug).
    func loadMapping(instanceID: String, chatSessionID: String?, allowLegacyFallback: Bool = false) -> (bridgeId: String?, claudeId: String?, projectPath: String?)? {
        guard let chatSessionID else { return nil }
        if let hit = Self.decodeMapping(key: Self.mappingKeyPrefix + instanceID + "." + chatSessionID) {
            return hit
        }
        guard allowLegacyFallback,
              let legacy = Self.decodeMapping(key: Self.mappingKeyPrefix + instanceID) else { return nil }
        if let data = try? JSONEncoder().encode(SessionMapping(bridgeId: legacy.bridgeId, claudeId: legacy.claudeId, projectPath: legacy.projectPath)) {
            UserDefaults.standard.set(data, forKey: Self.mappingKeyPrefix + instanceID + "." + chatSessionID)
        }
        logger.info("[CCPocket] migrated legacy per-instance mapping to chat session \(chatSessionID.prefix(8))")
        return legacy
    }

    /// Static read of the persisted Bridge session id for a chat
    /// conversation, without a live client (used by the session-list
    /// running dot). Instance-path legacy fallback lives in
    /// `loadPersistedBridgeId` below; the dot only needs the per-chat key.
    // MARK: - [Session sync] Remote inventory

    /// Map one wire session entry to a registry inventory entry. Live
    /// broadcast entries (SessionInfo) carry claudeSessionId; recent-index
    /// entries (sessions-index.json) carry sessionId (the provider session
    /// id — the Claude session id for Claude). Non-Claude providers and
    /// sidechain entries are skipped: the resume path is Claude-only today.
    static func remoteInventoryEntry(from s: CCPocketProtocol.ServerSession, isLive: Bool) -> BridgeRemoteSessionEntry? {
        if let provider = s.provider, provider != "claude" { return nil }
        if s.isSidechain == true { return nil }
        guard let claudeId = s.claudeSessionId ?? s.sessionId, claudeId.count > 8 else { return nil }
        return BridgeRemoteSessionEntry(
            bridgeId: isLive ? s.id : nil,
            claudeId: claudeId,
            name: s.name,
            preview: s.lastMessage ?? s.summary ?? s.lastPrompt ?? s.firstPrompt,
            projectPath: s.projectPath,
            updatedAt: parseBridgeDate(s.lastActivityAt)
                ?? parseBridgeDate(s.modified)
                ?? parseBridgeDate(s.createdAt)
                ?? parseBridgeDate(s.created),
            isLive: isLive
        )
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseBridgeDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw) ?? isoFractionalFormatter.date(from: raw)
    }

    /// Request the Bridge's recent-session index (`list_recent_sessions` →
    /// `recent_sessions`). The reply resumes the waiter and is NOT
    /// forwarded to `onMessage` (mirror of the history fetch pattern).
    /// Paged: the Bridge returns ~20 entries per page with hasMore — loop
    /// until exhausted (bounded at 3 pages / 600 entries).
    func fetchRecentSessions(timeout: TimeInterval = 15) async -> [CCPocketProtocol.ServerSession]? {
        guard task != nil else { return nil }
        guard recentWaiter == nil else { return nil }
        var collected: [CCPocketProtocol.ServerSession] = []
        let pageLimit = 200
        var offset = 0
        for _ in 0..<3 {
            let req = CCPocketProtocol.ListRecentSessionsRequest(limit: pageLimit, offset: offset)
            guard let payload = try? CCPocketProtocol.encode(req) else { break }
            do {
                try await send(payload, allowsReconnect: false)
            } catch {
                logger.warning("[CCPocket] list_recent_sessions send failed \(error.localizedDescription)")
                break
            }
            // Await the reply (timeout guard resumes nil).
            let message: CCPocketProtocol.ServerMessage? = await withCheckedContinuation { c in
                recentWaiter = c
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self else { return }
                    if let w = self.recentWaiter {
                        self.recentWaiter = nil
                        w.resume(returning: nil)
                    }
                }
            }
            guard let message else {
                logger.warning("[CCPocket] recent_sessions timeout after \(timeout)s")
                break
            }
            let page = message.sessions ?? []
            collected.append(contentsOf: page)
            if message.hasMore != true || page.isEmpty { break }
            offset += page.count
        }
        return collected.isEmpty ? nil : collected
    }

    /// One-shot Bridge inventory refresh for the session list: connect,
    /// pull `recent_sessions` (disk index — includes sessions started from
    /// other clients), push into the registry, disconnect. No agent session
    /// is started; safe to call repeatedly (registry merge is idempotent).
    /// MainActor: reads ProviderConfigStore.shared (actor-isolated) and
    /// pushes into the MainActor-confined registry.
    @MainActor
    static func refreshBridgeInventory(instanceID: String) async {
        guard let instance = ProviderConfigStore.shared.instances.first(where: {
            $0.id == instanceID && $0.providerType == .remoteAgent && $0.isEnabled
        }) else { return }
        guard let urlString = instance.effectiveCustomBaseURL,
              let baseURL = URL(string: urlString) else { return }
        let token = ProviderKeychainHelper.loadAPIKey(instanceId: instanceID) ?? ""
        let projectPath = RemoteAgentConnection.load(instanceID: instanceID)?.projectPath ?? "/tmp"
        let client = CCPocketClient(baseURL: baseURL, token: token)
        client.mappingInstanceID = instanceID
        do {
            try await client.connect(projectPath: projectPath)
            if let sessions = await client.fetchRecentSessions() {
                let entries = sessions.compactMap { Self.remoteInventoryEntry(from: $0, isLive: false) }
                await MainActor.run {
                    BridgeSessionRegistry.shared.setRecent(instanceID: instanceID, entries: entries)
                }
            }
            client.disconnect()
        } catch {
            client.disconnect()
        }
    }

    /// [Session sync] Claude + Bridge ids already bound to a local chat row
    /// for this instance (mapping enumeration) — the sidebar dedup key set.
    static func boundRemoteIds(instanceID: String) -> (claudeIds: Set<String>, bridgeIds: Set<String>) {
        let prefix = mappingKeyPrefix + instanceID + "."
        var claudeIds: Set<String> = []
        var bridgeIds: Set<String> = []
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let mapping = try? JSONDecoder().decode(SessionMapping.self, from: data) else { continue }
            if let claudeId = mapping.claudeId, claudeId.count > 8 {
                claudeIds.insert(claudeId)
            }
            if let bridgeId = mapping.bridgeId, !bridgeId.isEmpty {
                bridgeIds.insert(bridgeId)
            }
        }
        return (claudeIds, bridgeIds)
    }

    /// [Session sync] Reverse lookup: the local chat row bound to this
    /// Claude session id, if any.
    static func boundChatSessionID(instanceID: String, claudeId: String) -> String? {
        let prefix = mappingKeyPrefix + instanceID + "."
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let mapping = try? JSONDecoder().decode(SessionMapping.self, from: data),
                  mapping.claudeId == claudeId else { continue }
            return String(key.dropFirst(prefix.count))
        }
        return nil
    }

    /// [Session sync] Write a mapping for a synthetic row being
    /// materialized (the normal saveMapping path only runs on the live
    /// client after a turn, which has not happened for these rows yet).
    static func saveExplicitMapping(instanceID: String, chatSessionID: String, bridgeId: String?, claudeId: String, projectPath: String?) {
        guard claudeId.count > 8 else { return }
        let mapping = SessionMapping(bridgeId: bridgeId, claudeId: claudeId, projectPath: projectPath)
        let key = mappingKeyPrefix + instanceID + "." + chatSessionID
        if let data = try? JSONEncoder().encode(mapping) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func persistedBridgeId(instanceID: String, chatSessionID: String?) -> String? {
        guard let chatSessionID else { return nil }
        let key = Self.mappingKeyPrefix + instanceID + "." + chatSessionID
        guard let data = UserDefaults.standard.data(forKey: key),
              let mapping = try? JSONDecoder().decode(SessionMapping.self, from: data) else {
            return nil
        }
        return mapping.bridgeId
    }

    /// Bridge session id persisted at the last save. Used for cold-start
    /// reuse, independent of claudeId validity — a stale/cleared claudeId
    /// must not block reusing a still-live Bridge runtime session.
    func loadPersistedBridgeId(instanceID: String, chatSessionID: String?, allowLegacyFallback: Bool = false) -> String? {
        guard let chatSessionID else { return nil }
        if let data = UserDefaults.standard.data(forKey: Self.mappingKeyPrefix + instanceID + "." + chatSessionID),
           let mapping = try? JSONDecoder().decode(SessionMapping.self, from: data),
           let bridgeId = mapping.bridgeId {
            return bridgeId
        }
        // Same legacy migration as loadMapping (load path only).
        guard allowLegacyFallback,
              let data = UserDefaults.standard.data(forKey: Self.mappingKeyPrefix + instanceID),
              let mapping = try? JSONDecoder().decode(SessionMapping.self, from: data),
              let bridgeId = mapping.bridgeId else { return nil }
        return bridgeId
    }

    /// Cold-start reuse of a still-live Bridge session. The Bridge keeps the
    /// runtime session (and its SDK process) alive after our app process
    /// died, so input routed to the old bridge session id reaches it without
    /// spawning anything new — no new entry in the official client's running
    /// list (aligned with the official client's reconnect semantics: never
    /// re-run resume while the session survives).
    /// Returns true once the old id shows up in the Bridge's `session_list`;
    /// on failure the caller falls back to resume/start.
    func reuseBridgeSession(bridgeId: String) async -> Bool {
        guard !started, sessionId == nil else { return false }
        sessionId = bridgeId
        started = true
        for _ in 0..<50 { // up to 5 s for the session_list broadcast
            if let sessions = knownBridgeSessions, sessions.contains(where: { $0.id == bridgeId }) {
                logger.info("[CCPocket] reused live bridge session \(bridgeId.prefix(8))")
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Old session is gone (Bridge restarted / process evicted) — roll
        // back so the caller can resume/start fresh.
        started = false
        sessionId = nil
        logger.info("[CCPocket] bridge session \(bridgeId.prefix(8)) no longer alive — will resume")
        return false
    }

    // MARK: - Teardown

    /// Tear down the socket and its receive/ping loops but keep the session
    /// identity (`started`/`sessionId`/`claudeSessionId`). Used by the
    /// reconnect path so a reconnected socket routes `input` straight to the
    /// existing Bridge session instead of spawning a new agent process
    /// (aligned with the official client).
    /// Does not cancel `reconnectTask`: this runs *inside* it.
    private func teardownSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Deliberately keep started/sessionId/claudeSessionId — the Bridge
        // session is still alive and owns the agent process.
        resumeFailure = nil
        state = .idle
    }

    /// Full teardown: also forget the session identity. Used for deliberate
    /// disconnects (app teardown, provider switch).
    func disconnect() {
        teardownSocket()
        reconnectTask?.cancel()
        reconnectTask = nil
        // [Fix] Deliberately keep `onMessage`: a mid-turn reconnect must not
        // drop the stream handler (the turn's `result` would be lost and the
        // stream would hang). The provider clears it when the turn finishes.
        started = false
        sessionId = nil
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
