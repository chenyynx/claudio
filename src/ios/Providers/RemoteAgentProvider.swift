import Foundation

/// AgentProvider that drives a remote coding agent (Claude Code / Codex)
/// through a CC Pocket Bridge Server.
///
/// The Bridge owns the agent process and its session context; this provider
/// relays the user's latest message and re-maps Bridge stream events onto
/// OpenMinis' `AgentStreamEvent` so the chat engine and tool UI render them
/// unchanged.
///
/// Session lifecycle mirrors the official CC Pocket client:
/// - The first turn of a connection starts (or resumes) the agent session;
///   later turns reuse the same Bridge session.
/// - `resume_session` restores the same Claude conversation on relaunch
///   (id from the persisted per-instance mapping — never a stale id from an
///   earlier version, which caused cross-session bleed).
/// - The stream handler is installed *before* `input` is sent so no event
///   (including `result`) is lost in the race window.
final class RemoteAgentProvider: AgentProvider {

    var name: String { "CC Pocket Remote" }
    var model: LLMModel
    var defaultMaxTokens: Int { 16_384 }

    // [Decoupling] Protocol-level declaration — replaces runtime
    // `provider is RemoteAgentProvider` checks in AIChatViewModel.
    var isRemoteAgent: Bool { true }

    private let client: CCPocketClient
    private let instanceID: String
    /// Claude session id to resume on the first turn (nil = new session).
    private let restoreClaudeId: String?
    private var sessionStarted = false
    private let logger = AppLogger(category: "RemoteAgent")

    /// Whether a `.text` content block is currently open. The engine's
    /// stream consumer only accumulates `textDelta` into a block once
    /// `contentBlockStart(.text)` has been seen (currentTextBlockIdx is
    /// set there) — Bridge emits text as bare `stream_delta`/`result`
    /// events with no block framing, so we must open the block ourselves
    /// or every delta is silently dropped ("NO TEXT" at StreamEnd).
    private var textBlockStarted = false

    /// Thinking text accumulated this turn. Emitted as a `reasoningContent`
    /// event at turn end so the assistant message persists it (DB column
    /// reasoning_content) and survives session reload; without it the
    /// thinking blocks only exist in memory during streaming.
    private var thinkingAccumulator = ""

    /// [Per-session mapping] The chat conversation this provider serves.
    /// nil = detached sub-task (title generation etc.) — no mapping reads,
    /// no store retention, no identity persistence.
    let chatSessionID: String?
    /// 本 turn 用户带上的附件候选（vm 注入，发送时消费）。
    var pendingRemotePayloads: [AIChatViewModel.RemotePayload] = []
    /// Legacy per-instance mapping migration is opt-in from the load path.
    let allowLegacyMappingFallback: Bool

    init(model: LLMModel, client: CCPocketClient, instanceID: String, chatSessionID: String?, allowLegacyMappingFallback: Bool, restoreClaudeId: String?) {
        self.model = model
        self.client = client
        self.instanceID = instanceID
        self.chatSessionID = chatSessionID
        self.allowLegacyMappingFallback = allowLegacyMappingFallback
        self.restoreClaudeId = restoreClaudeId
    }

    // MARK: - AgentProvider

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        textBlockStarted = false
        thinkingAccumulator = ""
        logger.info("[RemoteAgent] stream start messages=\(messages.count)")
        let userRoles = messages.filter { $0.role == .user }.map { "\($0.parts.map { String(describing: $0) })" }
        logger.info("[RemoteAgent] user msgs=\(userRoles.count) parts=\(userRoles.joined(separator: " | "))")
        let userMessages = messages.filter { $0.role == .user }
        guard let userTextMessage = userMessages.reversed().first(where: { message in
            message.parts.contains { part in
                if case .text = part { return true }
                return false
            }
        }) else {
            logger.error("[RemoteAgent] FAIL: no user text found in messages — throwing sessionNotStarted")
            throw CCPocketError.sessionNotStarted
        }
        let lastUserText = userTextMessage.parts
            .compactMap({ part -> String? in
                if case .text(let text) = part { return text }
                return nil
            })
            .joined(separator: "\n")
        guard !lastUserText.isEmpty else {
            logger.error("[RemoteAgent] FAIL: no user text found in messages — throwing sessionNotStarted")
            throw CCPocketError.sessionNotStarted
        }

        // [Fix] If the socket died while the app was suspended, revive it
        // before this turn (reconnect happens async; a send failure would
        // queue the message and replay it after reconnect anyway).
        client.ensureConnected()

        // First turn of this connection: start (or resume) the Bridge session.
        // [Fix] `connect` no longer auto-starts; the agent process is only
        // spawned when a turn actually begins.
        if !sessionStarted {
            // [Fix] Cold-start reuse: the Bridge keeps the runtime session
            // (and its SDK process) alive after our app process died, so
            // route input straight to the persisted bridge session id — no
            // resume, no new runtime session in the official client's
            // running list (aligned with the official client). Fall back to
            // resume/start only when the old session is gone.
            if let bridgeId = client.loadPersistedBridgeId(
                    instanceID: instanceID,
                    chatSessionID: chatSessionID,
                    allowLegacyFallback: allowLegacyMappingFallback),
               await client.reuseBridgeSession(bridgeId: bridgeId) {
                sessionStarted = true
                client.boundChatSessionID = chatSessionID
                logger.info("[RemoteAgent] reused live bridge session on cold start")
            } else {
                await ensureSessionStarted()
            }
        }
        guard client.isStarted, let bridgeSessionId = client.sessionId else {
            logger.error("[RemoteAgent] FAIL: no bridge session id after start — aborting send to avoid cross-session bleed")
            throw CCPocketError.sessionNotStarted
        }

        // [Fix] Install the stream handler BEFORE sending input: events
        // (including the final `result`) arriving in the window between
        // send and handler-install used to be dropped, leaving the turn
        // hanging forever.
        let stream = AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            // [Fix] Only a *cancelled* stream (user stopped the turn) sends
            // `interrupt` — onTermination also fires on normal `.finished`,
            // and the Bridge has no idle guard: a late interrupt would kill
            // the next turn mid-generation. This stops the agent from
            // burning tokens on the machine after the user stopped.
            continuation.onTermination = { [weak self] termination in
                guard let self else { return }
                if case .cancelled = termination {
                    Task { await self.client.interrupt() }
                }
            }
            self.client.onMessage = { [weak self] message in
                guard let self else { return }
                let finished = self.handle(message, continuation: continuation)
                if finished {
                    self.client.onMessage = nil
                    // Turn ended — persist the session mapping so a relaunch
                    // resumes this conversation.
                    self.client.saveMapping(instanceID: self.instanceID, chatSessionID: self.chatSessionID)
                }
            }
            Task {
                do {
                    var inputText = lastUserText
                    var inlineImages: [[String: String]] = []
                    let payloads = self.pendingRemotePayloads
                    self.pendingRemotePayloads = []
                    for payload in payloads {
                        switch payload {
                        case .inlineImage(let data, let mimeType):
                            inlineImages.append(["base64": data.base64EncodedString(), "mimeType": mimeType])
                        case .uploadFile(let fileURL, let fileName):
                            do {
                                let projectPath = RemoteSessionDefaultsStore.load().projectPath
                                let result = try await RemoteFileUpload.upload(
                                    client: self.client,
                                    projectPath: projectPath,
                                    fileName: fileName,
                                    fileURL: fileURL
                                )
                                inputText += "\n\n[User uploaded file: \(result.fileName)]"
                                logger.info("[RemoteAgent] uploaded \(fileName) OK sha=\(result.sha256.prefix(8))")
                            } catch {
                                logger.error("[RemoteAgent] upload \(fileName) failed: \(error.localizedDescription)")
                                inputText += "\n\n[User attempted to attach \(fileName) but upload failed: \(error.localizedDescription)]"
                            }
                        }
                    }
                    try await self.client.sendInput(inputText, sessionId: bridgeSessionId, images: inlineImages.isEmpty ? nil : inlineImages)
                    logger.info("[RemoteAgent] sendInput OK session=\(bridgeSessionId) images=\(inlineImages.count) text=\(inputText.prefix(60).replacingOccurrences(of: "\n", with: " "))")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return stream
    }

    /// Start a fresh session, or resume the persisted conversation on the
    /// first turn. Falls back to a fresh session when resume fails.
    /// [Fix] `sessionStarted` is only set on success — otherwise a failed
    /// first turn (Bridge unreachable / timeout) would permanently poison
    /// the provider and every later turn would fail instantly.
    private func ensureSessionStarted() async {
        if let restoreClaudeId {
            do {
                try await client.resumeSession(claudeId: restoreClaudeId)
                logger.info("[RemoteAgent] resumed session claude=\(restoreClaudeId.prefix(8))...")
                sessionStarted = true
                client.boundChatSessionID = chatSessionID
                return
            } catch {
                logger.warning("[RemoteAgent] resume failed (\(error.localizedDescription)) — starting fresh")
            }
        }
        do {
            try await client.startSession()
            logger.info("[RemoteAgent] started fresh session")
            sessionStarted = true
            client.boundChatSessionID = chatSessionID
        } catch {
            logger.error("[RemoteAgent] start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Event mapping

    /// Map one Bridge message to AgentStreamEvent(s). Returns true when the
    /// turn has ended (result or error received).
    private func handle(
        _ message: CCPocketProtocol.ServerMessage,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) -> Bool {
        // [Fix] The Bridge broadcasts every session's events to all
        // connected clients. Only messages of OUR session (or id-less
        // global messages) may affect this turn — otherwise another
        // client's stream_delta/result would render into our UI and even
        // finish our turn (receiving-side cross-session bleed).
        guard message.sessionId == nil || message.sessionId == client.sessionId else {
            logger.info("[RemoteAgent] ignore event for session \(message.sessionId ?? "?") (ours=\(client.sessionId ?? "?"))")
            return false
        }
        // [Diag] Log every incoming event with its key payload.
        let payload: String = message.text.map { String($0.prefix(40)) }
            ?? message.result.map { String($0.prefix(40)) }
            ?? message.error
            ?? message.message.map { m -> String in
                switch m {
                case .assistant(let a): return "assistant/\(a.content?.count ?? 0)blocks"
                case .text(let t): return "text/\(t.prefix(30))"
                case .unknown: return "unknown"
                }
            }
            ?? message.subtype
            ?? ""
        logger.info("[RemoteAgent] <- \(message.type ?? "?")\(payload.isEmpty ? "" : " \(payload)")")
        switch message.type {
        case "system":
            // Only capture the short Bridge session id for routing; the
            // long Claude id is not a routing key.
            break

        case "status":
            // [Remote compaction] Bridge relays the SDK's compact_boundary
            // as {type:"status", status:"compacting"} — the only compaction
            // signal the client gets (no end event; the flag clears on the
            // next ordinary stream event). Local agents never see this wire
            // type, so the local path is untouched.
            if message.status == "compacting" {
                continuation.yield(.remoteCompactingStarted)
            }

        case "permission_request":
            // [M3] Approval flow (official PermissionRequestMessage):
            // surface the request to the UI, which answers with
            // approve / approve_always / reject / answer. Without this the
            // agent would wait forever in non-bypass permission modes.
            guard let toolId = message.toolUseId, let toolName = message.toolName else {
                logger.warning("[RemoteAgent] permission_request without id/name — ignored")
                break
            }
            let args: [String: Any] = (message.input ?? [:]).compactMapValues { value in
                switch value {
                case .string(let s): return s
                case .number(let n): return n
                case .bool(let b): return b
                default: return nil
                }
            }
            continuation.yield(.permissionRequest(id: toolId, toolName: toolName, input: args))

        case "stream_delta":
            if let text = message.text, !text.isEmpty {
                openTextBlockIfNeeded(continuation)
                continuation.yield(.textDelta(text))
            }

        case "thinking_delta":
            if let text = message.text, !text.isEmpty {
                if !thinkingAccumulator.isEmpty && !text.hasPrefix("\n") {
                    thinkingAccumulator += "\n"
                }
                thinkingAccumulator += text
                continuation.yield(.thinkingDelta(text))
            }

        case "assistant":
            if case .assistant(let m) = message.message, let content = m.content {
                for block in content {
                    switch block.type {
                    case "text":
                        if let text = block.text, !text.isEmpty, !textBlockStarted {
                            openTextBlockIfNeeded(continuation)
                            continuation.yield(.textDelta(text))
                        }
                    case "thinking":
                        // [Fix] Bridge's thinking block content lives under
                        // the `thinking` key, not `text`.  Read both for
                        // safety (legacy Codex may use text).
                        let text = block.thinking ?? block.text
                        if let t = text, !t.isEmpty, thinkingAccumulator.isEmpty {
                            continuation.yield(.thinkingDelta(t))
                        }
                    case "tool_use":
                        let toolName = block.name ?? "unknown"
                        let toolId = block.id ?? UUID().uuidString
                        let args: [String: Any] = (block.input ?? [:]).compactMapValues { value in
                            switch value {
                            case .string(let s): return s
                            case .number(let n): return n
                            case .bool(let b): return b
                            default: return nil
                            }
                        }
                        continuation.yield(.contentBlockStart(.toolUse(id: toolId, name: toolName)))
                        // [Fix] After tool_use the engine resets its text block index and waits for
                        // the provider to open a fresh `contentBlockStart(.text)`. Reset the flag
                        // so the next text section opens a new block instead of being silently dropped.
                        textBlockStarted = false
                        continuation.yield(.toolCallComplete(id: toolId, name: toolName, args: args, metadata: nil))
                        logger.info("[RemoteAgent] tool_use: \(toolName) id=\(toolId.prefix(8)) args=\(args.keys.sorted())")
                    default:
                        break
                    }
                }
            }

        case "result":
            // [Fix] Persist thinking accumulated this turn BEFORE finishing,
            // on every end path (success, stopped, error) — a lost turn used
            // to drop all of its reasoning.
            if !thinkingAccumulator.isEmpty {
                continuation.yield(.reasoningContent(thinkingAccumulator))
            }
            // Bridge wraps real failures as result subtype=error.
            if message.subtype == "error" {
                logger.error("[RemoteAgent] result/error: \(message.error ?? "?")")
                continuation.finish(throwing: CCPocketError.server(message.error ?? "Bridge error"))
                return true
            }
            // [Fix] subtype=stopped: the turn was interrupted (user stop or
            // another client). End the turn normally so the engine does not
            // hang; the next turn re-sends.
            if message.subtype == "stopped" {
                logger.info("[RemoteAgent] result/stopped — turn interrupted")
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
                return true
            }
            logger.info("[RemoteAgent] result/\(message.subtype ?? "?") text=\(message.result?.prefix(50) ?? "nil")")
            if let text = message.result, !text.isEmpty, !textBlockStarted {
                openTextBlockIfNeeded(continuation)
                continuation.yield(.textDelta(text))
            }
            let stopReason: AgentStopReason
            switch message.stopReason {
            case "tool_use": stopReason = .toolUse
            case "max_tokens", "length": stopReason = .maxTokens
            case "refusal": stopReason = .refusal
            default: stopReason = .endTurn
            }
            if let inputTokens = message.inputTokens, let outputTokens = message.outputTokens {
                continuation.yield(.usage(LLMUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationInputTokens: nil,
                    cacheReadInputTokens: nil
                )))
            }
            continuation.yield(.done(stopReason: stopReason))
            continuation.finish()
            return true

        case "error":
            let detail: String?
            if case .text(let t) = message.message { detail = t } else { detail = nil }
            let detailText = detail ?? message.error ?? "?"
            logger.error("[RemoteAgent] error msg: \(detailText)")
            // [Fix] Persist accumulated thinking before erroring so the
            // reasoning of a failed turn is not lost.
            if !thinkingAccumulator.isEmpty {
                continuation.yield(.reasoningContent(thinkingAccumulator))
            }
            // [Fix] "No active session" means the Bridge session was
            // destroyed server-side (stopped elsewhere / expired). Clear the
            // provider-side session so the next turn starts fresh instead of
            // failing forever.
            if detailText.contains("No active session") || message.errorCode == "session_not_found" {
                logger.warning("[RemoteAgent] session gone — resetting for next turn")
                sessionStarted = false
            }
            continuation.finish(throwing: CCPocketError.server(detailText))
            return true

        case "tool_result":
            // [Fix] Bridge executes tools server-side and streams results
            // here. Previously dropped: the engine's tool pairing never saw
            // a result, every tool block stayed .running, SafetyNet
            // force-closed it, and the persisted history showed "Tool
            // execution was interrupted" placeholders to the model on the
            // next turn. Aligned with bridge sdk-process.js:396
            // (type/toolUseId/content, toolName enriched by session.js).
            if let toolId = message.toolUseId, let output = message.content {
                let isError = output.hasPrefix("Tool execution was interrupted")
                    || output.hasPrefix("Error:")
                continuation.yield(.toolResult(id: toolId, name: message.toolName ?? "", output: output, isError: isError))
                logger.info("[RemoteAgent] tool_result: id=\(toolId.prefix(8)) name=\(message.toolName ?? "?") isError=\(isError) output=\(output.prefix(80).replacingOccurrences(of: "\n", with: " "))")
            }

        default:
            break
        }
        return false
    }

    /// [A-plan v1] Map one Bridge wire message onto an engine message — the
    /// replay counterpart of the live mapping in `handle(_:continuation:)`.
    /// Official semantics: history and live messages share one consumption
    /// pipeline (chat_session_cubit.dart:289-316); our equivalent is
    /// producing AgentMessages that ride buildRawMessage → toChatMessage.
    /// Thinking blocks fold into reasoningContent AND the uiSequence (so the
    /// per-block order survives the reload), user text stays .user.
    static func agentMessage(fromServer m: CCPocketProtocol.ServerMessage) -> AgentMessage? {
        switch m.type {
        case "assistant", "user":
            guard case .assistant(let am) = m.message, let blocks = am.content else { return nil }
            var parts: [AgentContentPart] = []
            var uiSeq: [UIBlockSnapshot] = []
            var thinking: [String] = []
            for b in blocks {
                switch b.type {
                case "text":
                    let t = b.text ?? ""
                    if t.isEmpty { continue }
                    parts.append(.text(t))
                    uiSeq.append(UIBlockSnapshot(kind: "text", text: t, toolId: nil))
                case "thinking":
                    // [Fix] Bridge's thinking block stores content under
                    // the `thinking` key, not `text` (verified against live
                    // bridge history payload).  Fall back to `text` for any
                    // legacy Codex shape that uses text.
                    let t = b.thinking ?? b.text ?? ""
                    if t.isEmpty { continue }
                    thinking.append(t)
                    uiSeq.append(UIBlockSnapshot(kind: "thinking", text: t, toolId: nil))
                case "tool_use":
                    guard let id = b.id else { continue }
                    let name = b.name ?? "unknown"
                    let args = Self.jsonArgs(from: b.input)
                    parts.append(.toolUse(id: id, name: name, input: args))
                    uiSeq.append(UIBlockSnapshot(kind: "tool", text: nil, toolId: id))
                default:
                    break
                }
            }
            if parts.isEmpty && thinking.isEmpty { return nil }
            let isUser = (am.role ?? "assistant") == "user"
            var msg = AgentMessage(role: isUser ? .user : .assistant, parts: parts)
            msg.uiSequence = uiSeq
            if !thinking.isEmpty {
                msg.reasoningContent = thinking.joined(separator: "\n")
            }
            return msg
        case "tool_result":
            // Same interrupted/error sniffing as the live path — placeholders
            // must be visible to the merge step, never rendered as success.
            guard let id = m.toolUseId else { return nil }
            let out = m.content ?? ""
            let isError = out.hasPrefix("Tool execution was interrupted")
                || out.hasPrefix("Error:")
            return AgentMessage(
                role: .user,
                parts: [.toolResult(id: id, name: m.toolName ?? "", content: out, isError: isError)]
            )
        default:
            // system / result / error / session_list ... carry no replayable content
            return nil
        }
    }

    /// [A-plan v1] Bridge wire messages → engine messages, in seq order.
    static func historyAgentMessages(from serverMessages: [CCPocketProtocol.ServerMessage]) -> [AgentMessage] {
        serverMessages.compactMap { agentMessage(fromServer: $0) }
    }

    /// Same conversion rules as the live `assistant` case in
    /// `handle(_:continuation:)`: only string / number / bool survive as
    /// tool input args (nested shapes dropped — the live path does the same).
    private static func jsonArgs(from input: [String: CCPocketProtocol.JSONValue]?) -> [String: Any] {
        guard let input else { return [:] }
        return input.compactMapValues { value -> Any? in
            switch value {
            case .string(let s): return s
            case .number(let n): return n
            case .bool(let b): return b
            default: return nil
            }
        }
    }

    /// Open a `.text` content block before the first text delta of a turn.
    /// Without it the engine's stream consumer never accumulates deltas
    /// (currentTextBlockIdx stays nil) and the final text is dropped.
    private func openTextBlockIfNeeded(
        _ continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) {
        guard !textBlockStarted else { return }
        textBlockStarted = true
        continuation.yield(.contentBlockStart(.text))
    }
}
