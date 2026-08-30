import Foundation

/// AgentProvider that drives a remote coding agent (Claude Code / Codex)
/// through a CC Pocket Bridge Server.
///
/// The Bridge owns the agent process and its session context; this provider
/// only relays the user's latest message and re-maps Bridge stream events
/// onto OpenMinis' `AgentStreamEvent` so the chat engine and tool UI can
/// render them unchanged.
final class RemoteAgentProvider: AgentProvider {

    var name: String { "CC Pocket Remote" }
    var model: LLMModel
    var defaultMaxTokens: Int { 16_384 }

    private let client: CCPocketClient
    private var sessionId: String?
    private let logger = AppLogger(category: "RemoteAgent")

    init(model: LLMModel, client: CCPocketClient) {
        self.model = model
        self.client = client
    }

    // MARK: - AgentProvider

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        // The Bridge maintains session context server-side; only the latest
        // user message is relayed (matches how the official CC Pocket client
        // sends `input` per turn).
        // [Diag] Full-chain diagnostics — every stage is logged so a failing
        // turn can be pinpointed from device logs alone.
        logger.info("[RemoteAgent] stream start messages=\(messages.count)")
        let userRoles = messages.filter { $0.role == .user }.map { "\($0.parts.map { String(describing: $0) })" }
        logger.info("[RemoteAgent] user msgs=\(userRoles.count) parts=\(userRoles.joined(separator: " | "))")
        guard let lastUserText = messages.last(where: { $0.role == .user })?.parts
            .compactMap({ part -> String? in
                if case .text(let text) = part { return text }
                return nil
            })
            .joined(separator: "\n"), !lastUserText.isEmpty else {
            logger.error("[RemoteAgent] FAIL: no user text found in messages — throwing sessionNotStarted")
            throw CCPocketError.sessionNotStarted
        }
        logger.info("[RemoteAgent] extracted text=\(lastUserText.prefix(50)) providerSession=\(sessionId ?? "nil") clientSession=\(client.sessionId ?? "nil")")

        // The Bridge replies to `start` with a system message carrying the
        // session id; if the first input races ahead of it, wait briefly rather
        // than sending a session-less input (Bridge rejects it with
        // "No active session. Send 'start' first.").
        var waited = 0
        while client.sessionId == nil && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        if client.sessionId == nil {
            logger.warning("[RemoteAgent] sessionId still nil after \(waited * 100)ms wait")
        } else {
            logger.info("[RemoteAgent] sessionId captured after \(waited * 100)ms")
        }
        try await client.sendInput(lastUserText, sessionId: sessionId ?? client.sessionId)
        logger.info("[RemoteAgent] sendInput OK session=\(sessionId ?? client.sessionId ?? "nil")")

        return AsyncThrowingStream { continuation in
            self.client.onMessage = { [weak self] message in
                guard let self else { return }
                let finished = self.handle(message, continuation: continuation)
                if finished {
                    self.client.onMessage = nil
                }
            }
        }
    }

    // MARK: - Event mapping

    /// Map one Bridge message to AgentStreamEvent(s). Returns true when the
    /// turn has ended (result or error received).
    private func handle(
        _ message: CCPocketProtocol.ServerMessage,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) -> Bool {
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
            if let sid = message.sessionId ?? message.claudeSessionId {
                sessionId = sid
            }

        case "stream_delta":
            if let text = message.text, !text.isEmpty {
                continuation.yield(.textDelta(text))
            }

        case "thinking_delta":
            if let text = message.text, !text.isEmpty {
                continuation.yield(.thinkingDelta(text))
            }

        case "assistant":
            if case .assistant(let m) = message.message, let content = m.content {
                for block in content {
                    switch block.type {
                    case "text":
                        if let text = block.text, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                    case "thinking":
                        if let text = block.text, !text.isEmpty {
                            continuation.yield(.thinkingDelta(text))
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
                        continuation.yield(.toolCallComplete(id: toolId, name: toolName, args: args, metadata: nil))
                    default:
                        break
                    }
                }
            }

        case "result":
            // Bridge wraps real failures as result subtype=error (error field
            // carries the text) — surface as an error, not a normal end-turn.
            if message.subtype == "error" {
                logger.error("[RemoteAgent] result/error: \(message.error ?? "?")")
                continuation.finish(throwing: CCPocketError.server(message.error ?? "Bridge error"))
                return true
            }
            logger.info("[RemoteAgent] result/\(message.subtype ?? "?") text=\(message.result?.prefix(50) ?? "nil")")
            // The Bridge's final assistant text arrives in `result` (not in an
            // assistant content block) — surface it before finishing the turn.
            if let text = message.result, !text.isEmpty {
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
            logger.error("[RemoteAgent] error msg: \(detail ?? message.error ?? "?")")
            continuation.finish(throwing: CCPocketError.server(detail ?? message.error ?? "Bridge error"))
            return true

        case "tool_result":
            // Tool execution results arrive here. M1 does not surface them in
            // the UI; M2 (tool cards) will render them via AgentStreamEvent.
            break

        default:
            break
        }
        return false
    }
}
