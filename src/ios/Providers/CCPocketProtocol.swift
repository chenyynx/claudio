import Foundation

// MARK: - CCPocket (K9i-0/ccpocket) Wire Protocol — M1 subset
//
// Client <-> Bridge Server JSON messages over a single WebSocket.
// Source of truth: packages/bridge/src/parser.ts in K9i-0/ccpocket.
// Parsing is intentionally lenient (all fields optional): the protocol
// evolves by adding messages, and unknown fields must not crash the client.

enum CCPocketProtocol {

    // MARK: - Client -> Server

    /// `client_capabilities` — sent immediately after connect. Tells the
    /// Bridge which server messages this client understands.
    struct ClientCapabilities: Encodable {
        let type = "client_capabilities"
        var protocolVersion: Int = 1
        var supportedServerMessages: [String] = [
            "system", "assistant", "stream_delta", "thinking_delta",
            "tool_result", "result", "error", "history",
        ]
    }

    /// `start` — open a new (or resume an existing) agent session.
    /// [Fix] Full field set aligned with the official client's
    /// ClientMessage.start (new_session_sheet.dart → session_list_screen
    /// _startNewSession): every optional session-start option the Bridge
    /// understands. Codex-only fields are sent only when provider == codex.
    struct StartRequest: Encodable {
        let type = "start"
        var projectPath: String
        var provider: String? = nil          // "claude" | "codex"
        var sessionId: String? = nil
        var `continue`: Bool? = nil
        var requestId: String? = nil
        var model: String? = nil
        var permissionMode: String? = nil
        var executionMode: String? = nil
        var planMode: Bool? = nil
        var effort: String? = nil
        var maxTurns: Int? = nil
        var maxBudgetUsd: Double? = nil
        var fallbackModel: String? = nil
        var forkSession: Bool? = nil
        var persistSession: Bool? = nil
        var useWorktree: Bool? = nil
        var worktreeBranch: String? = nil
        var existingWorktreePath: String? = nil
        // codex-only
        var approvalPolicy: String? = nil
        var approvalsReviewer: String? = nil
        var codexPermissionsMode: String? = nil
        var profile: String? = nil
        var sandboxMode: String? = nil
        var modelReasoningEffort: String? = nil
        var serviceTier: String? = nil
        var networkAccessEnabled: Bool? = nil
        var webSearchMode: String? = nil
        var additionalWritableRoots: [String]? = nil
        var autoRename: Bool? = nil
    }

    /// `approve` / `approve_always` / `reject` / `answer` — respond to a
    /// Bridge `permission_request` (official ClientMessage.approve /
    /// approveAlways / reject / answer in messages.dart:4591+). The id is
    /// the toolUseId from the request.
    struct PermissionResponseRequest: Encodable {
        let type: String          // "approve" | "approve_always" | "reject" | "answer"
        var id: String?
        var sessionId: String?
        var clearContext: Bool?
        var message: String?      // reject reason
        var toolUseId: String?    // answer
        var result: String?       // answer value
    }

    /// `input` — send a user message to the running session.
    struct InputRequest: Encodable {
        let type = "input"
        var text: String
        var sessionId: String?
        var clientMessageId: String?
        /// Claude Code 内联图片 base64（png/jpeg/gif/webp）。nil = 不带图。
        var images: [[String: String]]?
    }

    /// `resume_session` — restore a past agent session (official client flow).
    /// Unlike `start` (which opens a *new* Bridge runtime session), this asks
    /// the Bridge to restore an existing Claude conversation (from memory or
    /// disk) and report `session_resume_started` / `session_resume_failed`.
    struct ResumeSessionRequest: Encodable {
        let type = "resume_session"
        var sessionId: String?        // Claude session id (36 chars)
        var projectPath: String
        var provider: String?
        var permissionMode: String?
        var resumeRequestId: String?
    }

    /// `interrupt` — stop the current turn; the agent responds with
    /// `result subtype=stopped`.
    struct InterruptRequest: Encodable {
        let type = "interrupt"
        var sessionId: String?
    }

    /// `stop_session` — destroy a Bridge runtime session (official
    /// websocket.ts:4751): the Bridge broadcasts `result subtype=stopped`
    /// for it, destroys the session (kills the SDK agent process) and
    /// refreshes the session list. Claude conversation history on disk is
    /// untouched — the session resumes later via `resume_session`.
    struct StopSessionRequest: Encodable {
        let type = "stop_session"
        var sessionId: String
    }

    /// `get_history` — full conversation history replay for a Bridge session.
    /// Official semantics: the Bridge is the authoritative source for remote
    /// session restore; the reply (`history_snapshot` / `history_delta`)
    /// carries entries that ride the SAME pipeline as live messages
    /// (chat_session_cubit.dart:289-316 — history and live share one path).
    struct GetHistoryRequest: Encodable {
        let type = "get_history"
        var sessionId: String
    }

    /// [Session sync] Request the Bridge's recent-session index. NOTE:
    /// `list_sessions` merely re-sends the LIVE session list — the disk
    /// index (all clients' sessions, incl. WeChat-bridge ones) comes from
    /// `list_recent_sessions` (official messages.dart:4724), paged via
    /// limit/offset with hasMore on the reply.
    struct ListRecentSessionsRequest: Encodable {
        let type = "list_recent_sessions"
        var limit: Int?
        var offset: Int?
    }

    /// [Remote session options] Mid-session permission-mode switch
    /// (official messages.dart:4515 — mode: default/acceptEdits/plan/auto/
    /// bypassPermissions; plan mode derives from mode == "plan").
    struct SetPermissionModeRequest: Encodable {
        let type = "set_permission_mode"
        var mode: String
        var sessionId: String?
    }

    /// [Remote session options] Mid-session sandbox switch
    /// (official messages.dart:4585 — sandboxMode: "on"/"off").
    struct SetSandboxModeRequest: Encodable {
        let type = "set_sandbox_mode"
        var sandboxMode: String
        var sessionId: String?
    }

    // MARK: - Server -> Client (lenient parse)

    /// Raw server message. Decoded with all-optional fields so unknown
    /// message types or new fields never break the client.
    /// One entry of the Bridge's `session_list` payload. Carries both the
    /// short Bridge session id and the authoritative Claude session id —
    /// the reliable source for resume, since it is sent on every connection
    /// (even before any `result` event lands).
    struct ServerSession: Decodable, Sendable {
        let id: String?
        let claudeSessionId: String?
        let projectPath: String?
        let status: String?
        // [Session sync] Rich fields, all optional so older bridges never
        // break the lenient parse. Live broadcast entries (SessionInfo)
        // carry id/claudeSessionId/name/lastActivityAt...; recent-index
        // entries (sessions-index.json) carry sessionId (the provider
        // session id — the Claude session id for Claude), summary,
        // firstPrompt/lastPrompt, created/modified.
        let name: String?
        let provider: String?
        let lastMessage: String?
        let lastActivityAt: String?
        let createdAt: String?
        let sessionId: String?
        let summary: String?
        let firstPrompt: String?
        let lastPrompt: String?
        let created: String?
        let modified: String?
        let isSidechain: Bool?
    }

    struct ServerMessage: Decodable {
        let type: String?
        // system
        let subtype: String?
        let model: String?
        let provider: String?
        let projectPath: String?
        let sessionId: String?
        let claudeSessionId: String?
        let permissionMode: String?
        // assistant / error payload (object for assistant, string for error)
        let message: MessagePayload?
        // stream / thinking deltas
        let text: String?
        // tool result
        let toolUseId: String?
        let content: String?
        let toolName: String?
        let permissionOutcome: String?
        // permission_request payload (tool arguments; M3 approval flow)
        let input: [String: JSONValue]?
        // result
        let result: String?
        // `error` is used by result subtype=error payloads; plain `message`
        // strings are carried via `message` (see MessagePayload).
        let error: String?
        let stopReason: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let cost: Double?
        let duration: Double?
        let toolCalls: Int?
        // history
        let messages: [ServerMessage]?
        // history_snapshot / history_delta payload (bridge = authoritative
        // source for remote restore; entries replay through the live pipeline)
        let fromSeq: Int?
        let toSeq: Int?
        let reason: String?
        let entries: [HistoryEntry]?
        // session_list / recent_sessions
        let sessions: [ServerSession]?
        let hasMore: Bool?
        // resume flow
        let sourceSessionId: String?
        let resumeRequestId: String?
        // input ack / reject
        let acceptedSeq: Int?
        let queued: Bool?
        let historySeq: Int?
        // error
        let errorCode: String?
        let requestId: String?
        // request correlation
        let userMessageUuid: String?
        let clientMessageId: String?
        let baseSeq: Int?
        // system/supported_commands — 远端(服务器)技能清单
        let skills: [String]?
        let skillMetadata: [[String: JSONValue]]?
    }

    /// One seq-tagged entry of a `history_snapshot` / `history_delta`
    /// payload. `message` is the original wire message (assistant / user /
    /// tool_result / ...) — replayed through the live pipeline, never a
    /// separate render path (official: _runtimeStore.applyServerMessage).
    struct HistoryEntry: Decodable {
        let seq: Int?
        let message: ServerMessage?
    }

    /// `message` is polymorphic across server message types: an assistant
    /// object for `assistant` messages, a plain string for `error` messages.
    /// Decode to an enum so one ServerMessage struct carries both — and
    /// unknown shapes degrade to `.unknown` instead of dropping the message.
    enum MessagePayload: Decodable {
        case assistant(AssistantMessage)
        case text(String)
        case unknown

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s); return }
            if let a = try? c.decode(AssistantMessage.self) { self = .assistant(a); return }
            self = .unknown
        }
    }

    /// Content block inside an assistant message (text / thinking / tool_use).
    struct AssistantContentBlock: Decodable {
        let type: String?
        let text: String?
        let id: String?
        let name: String?
        let input: [String: JSONValue]?
    }

    struct AssistantMessage: Decodable {
        let id: String?
        let role: String?
        let content: [AssistantContentBlock]?
        let model: String?
    }

    /// Loose JSON value so tool inputs of any shape can be carried through.
    enum JSONValue: Decodable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([JSONValue])
        case object([String: JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let n = try? c.decode(Double.self) { self = .number(n); return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
            if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
            if c.decodeNil() { self = .null; return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unexpected JSON value")
        }
    }

    // MARK: - Helpers

    /// Serialize a request as a JSON object with "type" preserved.
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeServerMessage(_ data: Data) -> ServerMessage? {
        try? JSONDecoder().decode(ServerMessage.self, from: data)
    }
}
