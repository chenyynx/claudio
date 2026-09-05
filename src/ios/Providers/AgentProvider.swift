import Foundation

// MARK: - Cross-Provider Helpers

/// Sanitize a tool-use ID so it is valid for all providers.
/// Anthropic requires `^[a-zA-Z0-9_-]+$`; OpenAI Responses API can produce
/// IDs containing `|` (e.g. `call_xxx|fc_yyy`).  Replace any disallowed
/// character with `-`.
func sanitizeToolId(_ id: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
}

// MARK: - Canonical Tool Definitions

/// Canonical tool definition used by the agent loop — provider-agnostic.
struct AgentToolDefinition {
    let name: String
    let description: String
    let parameters: [String: AgentToolParam]
    let required: [String]
    /// Explicit property generation order. When provided, providers that support it
    /// (e.g. Gemini) will instruct the model to emit parameters in this order.
    let propertyOrdering: [String]?

    init(name: String, description: String, parameters: [String: AgentToolParam], required: [String], propertyOrdering: [String]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
        self.propertyOrdering = propertyOrdering
    }
}

struct AgentToolParam {
    let type: AgentParamType
    let description: String
    let enumValues: [String]?

    init(type: AgentParamType, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

enum AgentParamType: String {
    case string
    case integer
    case boolean
}

// MARK: - Agent Messages

/// A single content part in agent messages — provider-agnostic.
enum AgentContentPart: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    /// `imageLinuxPath` — iSH-visible linux path the image bytes were
    /// persisted to (e.g. `/var/minis/browser/<sid>/screenshot_*.jpg`,
    /// `/var/minis/attachments/uploads/*`). Carried so the request-level
    /// image budget can emit a re-fetchable text placeholder when the
    /// cumulative payload would exceed the 25MB cap. Defaults to nil for
    /// backward compatibility with existing call sites and persisted
    /// history.
    case toolResult(id: String, name: String, content: String, isError: Bool, imageData: Data? = nil, imageMimeType: String? = nil, pageURL: String? = nil, imageLinuxPath: String? = nil)
    /// `linuxPath` — same semantics as above. Used for user attachments
    /// and read_image results that don't ride through .toolResult.
    case imageData(data: Data, mimeType: String, linuxPath: String? = nil)
}

/// Native reasoning payload captured from the provider response, used to
/// preserve chain-of-thought across multi-turn requests. Lives **in memory
/// only** (not persisted) — restart loses encrypted content, which is
/// acceptable because the visible text + tool history is unchanged.
///
/// Each echo is tagged with the producing model so cross-model switches
/// (e.g. gpt-5.5 → deepseek) can be detected and the encrypted payload
/// stripped — encrypted_content is model-specific and meaningless to a
/// different model family.
struct ReasoningEcho: @unchecked Sendable {
    /// Stable provider family tag; matches `OpenAIAgentProvider.responsesAPIProviderKind`
    /// etc. Different families never share schemas.
    let providerKind: String
    /// Concrete model id (e.g. "gpt-5.5", "o3-mini"). Encrypted payloads are
    /// only safe to echo back to the **same** model id within the same
    /// provider family.
    let modelId: String
    /// Reasoning items captured in original emission order — must be
    /// re-inserted into the next request's input array in the same order
    /// (Responses API rejects out-of-order reasoning items).
    let items: [Item]

    enum Item: @unchecked Sendable {
        /// OpenAI Responses API reasoning item.
        case openaiReasoning(id: String, encryptedContent: String?, summary: [String])
    }
}

/// One entry of the UI block sequence snapshot. Preserves the exact
/// thinking/tool/text interleaving and per-thinking-block content across a
/// relaunch — the local equivalent of the official client's content-array
/// rendering (chat_session_cubit renders `message.content` in order).
struct UIBlockSnapshot: Codable, Hashable, Sendable {
    let kind: String      // "thinking" | "tool" | "text"
    let text: String?     // content for thinking/text blocks
    let toolId: String?   // toolUseId for tool blocks (content comes from parts)
}

/// A message in the agent conversation.
struct AgentMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    var parts: [AgentContentPart]
    /// UI block sequence snapshot (see UIBlockSnapshot). Persisted so a
    /// relaunch rebuilds blocks in the exact original order (multiple
    /// thinking segments interleaved with tool calls stay intact — the
    /// merged `reasoningContent` alone cannot). nil = legacy message
    /// (fall back to parts-based reconstruction).
    var uiSequence: [UIBlockSnapshot]? = nil
    /// True when this assistant message was interrupted mid-stream (e.g. network drop).
    /// tool_use blocks inside may have incomplete/empty inputs (partialJson never finished).
    /// Placeholder tool_results must NOT be injected for interrupted messages, because
    /// sending a tool_result for a tool_use with empty input causes API 400 errors.
    var isInterrupted: Bool = false
    /// Opaque reasoning content from thinking models (e.g. Kimi, DeepSeek, QwQ).
    /// Must be echoed back on assistant messages for multi-turn conversations.
    var reasoningContent: String?
    /// Native reasoning payload (Responses-API encrypted items, etc.). In
    /// memory only — see `ReasoningEcho` for cross-model isolation rules.
    var reasoningEcho: ReasoningEcho?
    /// DB message id (RawMessage.id) once this message has been persisted.
    /// Populated by persistAgentMessage after buildRawMessage succeeds, or by
    /// loadSession on restore. Used by compact logic to resolve marker boundaries
    /// via id instead of sort_order. nil while the message is still in-flight
    /// (e.g. mid-stream before persist).
    var dbMessageId: String? = nil
    /// Bridge-side message sequence number, set from ServerMessage.historySeq when
    /// converting bridge wire messages to AgentMessages for history replay.
    /// Used by RemoteHistoryBackfill to perform incremental sync:
    /// messages with seq <= lastSyncedBridgeSeq are already local and skipped;
    /// only messages with seq > lastSyncedBridgeSeq are new and need appending.
    /// nil for in-memory messages (not from bridge history replay).
    var bridgeSeq: Int? = nil

    /// [Fix 2026-09-05 bug 1] Single source of truth for the RawMessage id
    /// derived from an AgentMessage. Shared between production
    /// (`buildRawMessage` in `AIChatViewModel+Persistence`) and the unit
    /// test (`makeBuildRaw` in `RemoteHistoryBackfillTests`) so the two
    /// cannot drift again — a previous test/prod mismatch (UUID() in prod
    /// vs "bridge-{seq}" in test) silently broke id-based dedup in prod
    /// while the test suite passed.
    ///
    /// - bridgeSeq present → deterministic `bridge-{seq}`, so re-running
    ///   `BackfillCore.computePlan` against the same bridge history hits the
    ///   existing-ids set instead of re-appending duplicates.
    /// - bridgeSeq nil → fresh UUID each call (live-stream path, no replay).
    func rawMessageId() -> String {
        if let seq = bridgeSeq { return "bridge-\(seq)" }
        return UUID().uuidString
    }
}

// MARK: - Stream Events

/// Stream events from an agent provider — unified across Anthropic/Gemini.
enum AgentStreamEvent: @unchecked Sendable {
    /// A new content block started (text or tool).
    case contentBlockStart(AgentBlockStart)
    /// Incremental text delta.
    case textDelta(String)
    /// Tool input update (for streaming JSON preview).
    /// `accumulated` is the full JSON so far, `name` is the tool name.
    case toolInputDelta(name: String, accumulated: String)
    /// Tool call completed with final parsed arguments.
    case toolCallComplete(id: String, name: String, args: [String: Any], metadata: ToolCallMetadata?)
    /// Usage stats.
    case usage(LLMUsage)
    /// Real-time thinking content delta for live UI display.
    case thinkingDelta(String)
    /// Accumulated reasoning content from thinking models (opaque, must be echoed back).
    case reasoningContent(String)
    /// Native reasoning payload (e.g. OpenAI Responses-API encrypted items)
    /// for in-memory multi-turn replay. Cross-model isolation rules live on
    /// `ReasoningEcho`.
    case reasoningEcho(ReasoningEcho)
    /// Tool execution result from the agent, paired by tool_use id.
    /// The CC Pocket Bridge executes tools server-side and streams results
    /// via `tool_result` (toolName enriched by the Bridge — session.js);
    /// without this event the engine's tool pairing never completes (blocks
    /// stay .running → SafetyNet force-cancels → persisted history shows
    /// "Tool execution was interrupted" to the model on the next turn).
    case toolResult(id: String, name: String, output: String, isError: Bool)
    /// Bridge `permission_request` — the agent wants to run a tool that
    /// needs approval (non-bypass permission mode). The UI shows the
    /// approval dialog and answers with approve / approve_always / reject
    /// (official PermissionRequestMessage + ApprovalBar).
    case permissionRequest(id: String, toolName: String, input: [String: Any])
    /// Bridge `status:"compacting"` — the remote Claude Code session is
    /// auto-compacting its context (Bridge relays the SDK's
    /// `compact_boundary` event). Emitted ONLY by RemoteAgentProvider;
    /// local providers never produce it. The Bridge wire carries no end
    /// event — consumers clear the flag on the next ordinary stream event
    /// (mirroring Bridge sdk-process.ts updateStatusFromMessage:
    /// compacting → running on next assistant/user/result).
    case remoteCompactingStarted
    /// Response finished.
    case done(stopReason: AgentStopReason)
}

enum AgentBlockStart: Sendable {
    case text
    case toolUse(id: String, name: String)
}

enum AgentStopReason: Sendable {
    case endTurn
    case toolUse
    case maxTokens
    /// Anthropic safety classifier declined the request (HTTP 200 + `stop_reason: "refusal"`,
    /// input tokens billed, empty `content`). Distinct from `.endTurn` so the agent loop can
    /// surface an actionable message instead of a generic "empty response" and skip the
    /// pointless transient-retry path (a refusal is deterministic, not transient).
    /// Fires as a false-positive on Fable 5 for benign turns carrying the large Claude Code
    /// agentic system prompt + tool set. See [T-ios-fable5-empty-response].
    case refusal
}

/// Provider-specific metadata attached to a tool call (e.g. Gemini thought signatures).
struct ToolCallMetadata: @unchecked Sendable {
    let thoughtSignature: String?
}

// MARK: - Protocol

/// Protocol for providers that support the agent loop (streaming + tool use).
protocol AgentProvider {
    var name: String { get }
    var model: LLMModel { get }
    /// Default max output tokens for this provider.
    var defaultMaxTokens: Int { get }
    /// True for providers that drive a remote agent (e.g. CC Pocket Bridge).
    /// Declared in the protocol to ensure dynamic dispatch (protocol
    /// extension members are statically dispatched — a conformer override
    /// would be ignored when accessed through the protocol type).
    var isRemoteAgent: Bool { get }
    /// Bridge-side history sequence of the most recent message the provider
    /// received during the current/last turn. nil for local providers, and
    /// nil on a fresh provider before the first wire event arrives. Used by
    /// the persistence layer to derive a stable `RawMessage.id` ("bridge-{seq}")
    /// that matches the id the backfill path will re-derive from history replay
    /// — without this, the live path and the backfill path produce disjoint
    /// id sets and BackfillCore.computePlan cannot dedup (the root cause of
    /// the duplicate-render / role-mismatch / kill-reenter cluster).
    /// ccpocket official uses runtime-store seq; Claudio persists to SQLite
    /// (per dev-rules 1 段) so we mirror the seq onto our own row.id instead.
    var lastBridgeSeq: Int? { get }

    /// Provider-specific streaming implementation. Receives a thinking level
    /// that has already been clamped to the model's effective max by the
    /// protocol extension — implementations should NOT re-clamp.
    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>
}

extension AgentProvider {
    /// True for providers that drive a remote agent (e.g. CC Pocket Bridge).
    /// Local providers (Anthropic/Gemini/OpenAI/...) default to false via
    /// this extension. Used by the engine core to branch trim and
    /// tool-execution behavior WITHOUT runtime type checks
    /// (`provider is RemoteAgentProvider`).
    var isRemoteAgent: Bool { false }
    /// Local providers never see a bridge seq. Default to nil so callers
    /// can pass the value through unchanged — local persistAgentMessage
    /// calls then fall back to `msg.rawMessageId()`'s UUID branch,
    /// preserving the previous (single-source) behavior.
    var lastBridgeSeq: Int? { nil }

    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let clamped = min(thinkingLevel, model.catalogMaxThinkingLevel)
        return try await streamAgentMessageClamped(
            messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, thinkingLevel: clamped
        )
    }

    /// Default: thinking off.
    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamAgentMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, thinkingLevel: .off)
    }
}

