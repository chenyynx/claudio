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
        guard let lastUserText = messages.last(where: { $0.role == .user })?.parts
            .compactMap({ part -> String? in
                if case .text(let text) = part { return text }
                return nil
            })
            .joined(separator: "\n"), !lastUserText.isEmpty else {
            throw CCPocketError.sessionNotStarted
        }

        try await client.sendInput(lastUserText, sessionId: sessionId ?? client.sessionId)

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
            if let content = message.message?.content {
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
            continuation.finish(throwing: CCPocketError.server(message.error ?? "Bridge error"))
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
