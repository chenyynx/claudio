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
    struct StartRequest: Encodable {
        let type = "start"
        var projectPath: String
        var provider: String?          // "claude" | "codex"
        var sessionId: String?
        var `continue`: Bool?
        var requestId: String?
        var model: String?
        var permissionMode: String?
    }

    /// `input` — send a user message to the running session.
    struct InputRequest: Encodable {
        let type = "input"
        var text: String
        var sessionId: String?
        var clientMessageId: String?
    }

    // MARK: - Server -> Client (lenient parse)

    /// Raw server message. Decoded with all-optional fields so unknown
    /// message types or new fields never break the client.
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
        // error
        let errorCode: String?
        let requestId: String?
        // request correlation
        let userMessageUuid: String?
        let clientMessageId: String?
        let baseSeq: Int?
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
