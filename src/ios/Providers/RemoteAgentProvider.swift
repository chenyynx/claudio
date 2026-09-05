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

    /// [Fix 2026-09-05 route D] Bridge-side history seq of the most recent
    /// wire message we observed in `handle()`. Captured here so the
    /// persistence layer (runAgentLoop caller) can read it AFTER the
    /// stream ends and stamp `RawMessage.id` with the SAME
    /// "bridge-{seq}" string that `agentMessage(fromServer:)` produces
    /// for the history-replay path — without this alignment, the live
    /// path writes UUIDs that the backfill path's id-set never matches
    /// and BackfillCore.computePlan re-appends everything (Bug D root cause).
    ///
    /// Thread safety: `handle` runs on the WebSocket callback thread
    /// (`client.onMessage`); the read site is `runAgentLoop` on the engine
    /// actor. `RemoteAgentProvider` is a regular class, so we guard
    /// access with an NSLock — using `withLock{}` (the async-safe scoped
    /// form, since bare `lock()/unlock()` is unavailable from async
    /// contexts in Swift 6, see Bug经验库 「acb6234 编译失败: 去 @MainActor
    /// 必查 3 件套」).
    private var _lastBridgeSeq: Int? = nil
    private let seqLock = NSLock()
    var lastBridgeSeq: Int? { seqLock.withLock { _lastBridgeSeq } }

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
                                // [Fix 2026-09-05] Build <user-attached-files> XML
                                // with the bridge host's full path so the agent can
                                // Read the file. Mirrors the local agent's format in
                                // AIChatViewModel.swift:2662-2670 — ChatStore.toChatMessage
                                // (4832-4900) already strips the XML from user-visible
                                // display text and parses the <file> element into
                                // AttachmentMeta for tile rendering. Old plain-text
                                // "[User uploaded file: X]" had no path (agent couldn't
                                // find the file) AND leaked the marker into the bubble
                                // after backfill, because stripAttachmentMarkers only
                                // matches the image-attachment patterns.
                                let xml = Self.buildUserAttachedFilesXML(
                                    projectPath: projectPath,
                                    fileName: result.fileName,
                                    sizeBytes: result.sizeBytes
                                )
                                inputText += "\n\n\(xml)"
                                logger.info("[RemoteAgent] uploaded \(fileName) OK sha=\(result.sha256.prefix(8)) size=\(result.sizeBytes)")
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
        // [Fix 2026-09-05 route D] Capture the bridge seq for this wire
        // message. Every broadcast message carries `historySeq` (set by
        // bridge/session.ts:917 `appendHistoryToSession`, the single-entry
        // chokepoint), so the value is monotonic and unique per broadcast.
        // The persistence layer reads `lastBridgeSeq` AFTER the stream ends
        // and injects it into the final AgentMessage so `rawMessageId()`
        // produces "bridge-{seq}" — matching the id set the backfill path
        // will re-derive. PastHistory messages (splitPastHistoryMessages)
        // don't get a seq, so we ignore nil (live stream never sees them,
        // and the persistence path falls back to UUID, same as before).
        if let seq = message.historySeq {
            seqLock.withLock { _lastBridgeSeq = seq }
            // [Diag 2026-09-05 路线 D 排障锚点] live 路径 seq 抓取时打点。
            // 未来"重复渲染 / role 错配"复发，看这里 seq 是否单调递增即可定位
            // 是不是 id 派生这一段没工作（缺失=live 路径根本没收过 seq）。
            logger.debug("[BridgeSeq] live captured=\(seq) type=\(message.type)")
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
                // Bridge sends both cache_creation and cache_read on the
                // result payload; pass them through so the Token Usage
                // sheet can show the full cache breakdown. LLMUsage names
                // its read field cacheReadInputTokens (vs the wire's
                // cachedInputTokens) — that historical name map is
                // resolved right here.
                continuation.yield(.usage(LLMUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationInputTokens: message.cacheCreationInputTokens,
                    cacheReadInputTokens: message.cachedInputTokens
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
                // [Claudio 2026-09-05] Detect remote agent's tool output file
                // (Write tool produced a downloadable file). Yield a side-band
                // event so viewModel can fill AssistantBlock.outputFile* fields
                // WITHOUT polluting the AgentContentPart.toolResult tuple (which
                // would force changes in 8+ call sites across SSEStream/Offloading/
                // RequestBudget/ConcurrentTools). The viewModel handler persists
                // via ChatStore so backfill on relaunch restores the card.
                if let of = Self.parseRemoteOutputFile(
                    message: message,
                    output: output,
                    toolName: message.toolName
                ) {
                    continuation.yield(.remoteFileAttached(toolUseId: toolId, file: of))
                    logger.info("[RemoteAgent] remoteFileAttached: id=\(toolId.prefix(8)) name=\(of.fileName) size=\(of.sizeBytes) mime=\(of.mimeType ?? "?")")
                }
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
            // [M4 09-05] 提取桥端 historySeq（写于 bridge/session.ts:917 appendHistoryToSession）
            // 用于 RemoteHistoryBackfill 增量同步。ServerMessage.historySeq 在
            // CCPocketProtocol 已声明为 Int?，这里强转取出。
            if let seq = m.historySeq {
                msg.bridgeSeq = seq
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

    // MARK: - XML 构造（pure helper，可单测）

    /// Build the `<user-attached-files>` XML block that the bridge agent reads
    /// to know which files were uploaded and where they live on the bridge host.
    /// Mirrors the local agent's format in `AIChatViewModel.swift:2662-2670` so
    /// the SAME `ChatStore.toChatMessage` consumer (4832-4900) can parse the
    /// `<file>` element into `AttachmentMeta` and strip the XML from the
    /// user-visible bubble. Live UI is also clean (the bubble is built from the
    /// user's typed text in `AIChatViewModel.send()` line 2442-2443, not from
    /// this XML). `now` is injectable so the test can pin the timestamp without
    /// freezing `Date()`.
    ///
    /// [Fix 2026-09-05] Replaces the old plain-text marker
    /// `"[User uploaded file: X]"` which (1) had no path, so the agent
    /// couldn't `Read` the file, and (2) leaked to the UI after backfill
    /// because `ChatStore.stripAttachmentMarkers` only matches the
    /// image-attachment patterns.
    static func buildUserAttachedFilesXML(
        projectPath: String,
        fileName: String,
        sizeBytes: Int,
        now: Date = Date()
    ) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        return """
        <user-attached-files>
          <file path="\(projectPath)/\(fileName)" size="\(sizeBytes)" modified="\(isoFormatter.string(from: now))" />
        </user-attached-files>
        """
    }

    // MARK: - 远端工具输出文件检测（2026-09-05 新增）

    /// [Claudio 2026-09-05] Extract a downloadable file reference from a
    /// `tool_result` ServerMessage. Two strategies, in order:
    ///
    /// 1. **Structured (preferred)** — ccpocket upstream is expected to add a
    ///    `outputFile: {path, sizeBytes, sha256, mimeType}` field on
    ///    `tool_result` (mirroring `file_download_ready`'s shape at
    ///    websocket.ts:1197-1205). When present, parse directly. **Currently
    ///    upstream does NOT carry this field** (verified 2026-09-05 against
    ///    websocket.ts:2370-2377); this branch activates after a PR lands.
    ///
    /// 2. **Text fallback (temporary)** — Claude Code's Write tool result
    ///    reads `"File created successfully at: /abs/path"` (verified via
    ///    ccpocket probe). Match that pattern; size unknown → 0. Codex may
    ///    use a different format; we match what Claude Code emits and
    ///    silently return nil otherwise.
    ///
    /// Returns nil for non-Write tools (Bash / Read / Edit / etc.) — we only
    /// show a file card when the tool actually produced a file the user
    /// would want to download.
    static func parseRemoteOutputFile(
        message: CCPocketProtocol.ServerMessage,
        output: String,
        toolName: String?
    ) -> RemoteOutputFile? {
        // Only Write-like tools can produce a file artifact. Reject early
        // for the common case (Bash/Read/Edit/Glob/Grep/...) so we don't
        // burn regex on every tool_result.
        guard let name = toolName?.lowercased() else { return nil }
        let writeLikeNames: Set<String> = ["write", "file_write", "create_file", "edit"]
        guard writeLikeNames.contains(name) else { return nil }

        // Strategy 1: structured outputFile (when upstream lands)
        // ServerMessage is intentionally lenient — no outputFile field yet,
        // so this branch is dormant. When ccpocket adds the field, decode
        // it here and return.
        // TODO [Claudio 2026-09-05]: when ccpocket PR lands, decode
        //   message.outputFile here. Tracked in C-3 待办.

        // Strategy 2: text fallback. Claude Code emits:
        //   "File created successfully at: /abs/path"
        //   "File ... at /abs/path" (older variants)
        // Regex matches "at <abs path>" — single line, ends at newline.
        let pattern = #"(?:created|written|saved|wrote)\s+(?:successfully\s+)?at:?\s+(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges >= 2,
              let pathRange = Range(match.range(at: 1), in: output)
        else { return nil }
        let path = String(output[pathRange]).trimmingCharacters(in: .whitespaces)
        // Strip trailing punctuation (period, comma) that some variants include.
        let cleanedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        // Must look like a real path (starts with /)
        guard cleanedPath.hasPrefix("/") else { return nil }
        let fileName = (cleanedPath as NSString).lastPathComponent
        return RemoteOutputFile(
            filePath: cleanedPath,
            fileName: fileName,
            sizeBytes: 0,            // unknown via text; UI shows nothing
            sha256: nil,
            mimeType: nil            // inferred from extension by FileAttachmentCard
        )
    }
}
