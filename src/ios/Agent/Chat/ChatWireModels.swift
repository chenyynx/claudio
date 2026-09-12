// ChatWireModels — 消息持久化模型（从 ChatStore.swift 整段抽出，[G-3 2026-09-12]）。
//
// 抽出动机：RemoteHistory 校准链（ReplayRowId / RemoteHistoryIdentity /
// RemoteHistorySyncCore / RemoteSyncSegmentRegistry）是**纯函数**设计，其单测
// 却被绑在"必须装整个 App 才能跑"的 xcodebuild test 门上——CI 的
// Designed-for-iPad 目的地因签名门禁（无 Apple 证书，KSign 免签路线）
// 从未真正跑过测试（0xe800801c/0xe8008014，v1.14.29 起 6 连红）。
// 本文件+4 个纯文件经 symlink 组成 test-only SwiftPM 包（Packages/RemoteHistoryKit），
// `swift test` 无签名/无目的地直接跑。
//
// ⚠️ 纯位移零行为变化：以下类型定义逐字节来自 ChatStore.swift 177-474。
// App target 与本包各编译一份（app 不 import 本包，无类型冲突）。

import Foundation

/// Role for a raw message turn.
enum MessageRole: String, Codable {
    case user
    case assistant
}

/// Reference to a media file stored in Library/MinisChat/minis/<sessionId>/
struct MediaRef: Codable, Hashable {
    let id: String
    let relativePath: String
    let mimeType: String
    let originalFileName: String?
    /// iSH-visible linux path the file is mirrored to (e.g.
    /// `/var/minis/attachments/uploads/<name>`, `/var/minis/browser/<sid>/...`).
    /// Optional — older persisted rows decode with `nil` and fall back to
    /// spillover at request-budget elide time. New writes always populate
    /// this when the file is offloaded to iSH-visible storage.
    let linuxPath: String?

    init(id: String, relativePath: String, mimeType: String, originalFileName: String?, linuxPath: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.originalFileName = originalFileName
        self.linuxPath = linuxPath
    }
}

/// A tool call requested by the assistant.
struct ToolUse: Codable, Hashable {
    let toolUseId: String
    let name: String
    let input: String
    let description: String?
    let thoughtSignature: String?  // Gemini 3.x thought signature
}

/// A snapshot captured from a tool execution result.
struct ToolSnapshot: Codable, Hashable {
    enum SnapshotType: String, Codable, Hashable {
        case text
        case image
    }
    let type: SnapshotType
    let text: String?        // For .text snapshots (last N lines of output)
    let mediaRef: MediaRef?  // For .image snapshots (browser screenshot)
    let duration: TimeInterval?  // Execution duration in seconds
}

/// Result of executing a tool.
struct ToolResult: Codable, Hashable {
    let toolUseId: String
    let output: String
    let success: Bool
    let mediaRef: MediaRef?
    let snapshot: ToolSnapshot?
    /// Final page URL after browser tool execution (for display in tool detail sheet).
    /// Truncated to ≤512 characters if the original was longer.
    let pageURL: String?
    /// Terminal execution status: "success" | "failed" | "cancelled".
    /// Optional for backward compatibility with rows written before this field existed;
    /// when nil, callers fall back to `success` (which cannot distinguish failed from cancelled).
    let status: String?
    /// [Claudio 2026-09-05] Remote agent's tool output file metadata. Only populated
    /// for the remote (bridge) channel when bridge reports `tool_result.outputFile`
    /// (ccpocket websocket.ts:2370-2377 — currently absent; pending upstream PR to
    /// add structured `outputFile: {path, sizeBytes, sha256, mimeType}` to the
    /// `tool_result` ServerMessage). When upstream lands, App drops its
    /// "File created at <path>" text fallback in RemoteAgentProvider.
    /// Optional for backward compatibility with rows written before this field existed.
    let outputFile: RemoteOutputFile?

    /// Truncate a URL to at most `maxLength` characters by eliding the middle.
    /// Returns the original if it's already short enough.
    static func truncateURL(_ url: String, maxLength: Int = 512) -> String {
        guard url.count > maxLength else { return url }
        let marker = "…[truncated]…"
        let keep = (maxLength - marker.count) / 2
        let head = String(url.prefix(keep))
        let tail = String(url.suffix(keep))
        return head + marker + tail
    }
}

/// [Claudio 2026-09-05] Structured metadata for a remote agent's tool output file.
/// Mirrors the eventual `outputFile` field on ccpocket's `tool_result` ServerMessage.
/// See ccpocket bridge `prepareFileDownload` (websocket.ts:1076-1205) for the
/// matching `file_download_ready` shape (filePath / fileName / mimeType /
/// sizeBytes / downloadUrl).
///
/// `filePath` is the **absolute** path on the bridge host (e.g. "/home/ubuntu/x.py").
/// The App converts it to a project-relative path before sending
/// `prepare_file_download` (which rejects absolute paths per
/// websocket.ts:1082-1090).
struct RemoteOutputFile: Codable, Hashable, Sendable {
    let filePath: String
    let fileName: String
    let sizeBytes: Int64
    let sha256: String?
    let mimeType: String?
}

/// A single content part within a message — the atomic unit.
enum ContentPart: Codable, Hashable {
    case text(String)
    case mediaRef(MediaRef)
    case toolUse(ToolUse)
    case toolResult(ToolResult)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum PartType: String, Codable {
        case text
        case mediaRef
        case toolUse
        case toolResult
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(s, forKey: .value)
        case .mediaRef(let ref):
            try container.encode(PartType.mediaRef, forKey: .type)
            try container.encode(ref, forKey: .value)
        case .toolUse(let tu):
            try container.encode(PartType.toolUse, forKey: .type)
            try container.encode(tu, forKey: .value)
        case .toolResult(let tr):
            try container.encode(PartType.toolResult, forKey: .type)
            try container.encode(tr, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let partType = try container.decode(PartType.self, forKey: .type)
        switch partType {
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .mediaRef:
            self = .mediaRef(try container.decode(MediaRef.self, forKey: .value))
        case .toolUse:
            self = .toolUse(try container.decode(ToolUse.self, forKey: .value))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .value))
        }
    }
}

/// A compact boundary marker in a session's message history.
/// Represents the point where older messages were summarized to save context.
///
/// Identity model (post Phase A):
///   - `firstKeptMessageId` is the authoritative active-region start.
///   - `lastCompactedMessageId` is the last message in the compacted range.
///   - Sort-order fields (`firstKeptSortOrder`, `uiBoundarySortOrder`) and
///     `boundaryMessageId` are retained for legacy markers and cross-device
///     sync compatibility with older builds, used only as fallbacks.
struct CompactMarker: Identifiable, Codable {
    let id: String
    let sessionId: String
    /// LLM-generated summary of the compacted messages.
    let summary: String
    /// LEGACY: sort_order of the first message AFTER the compacted range.
    /// Only used as fallback when firstKeptMessageId resolution fails.
    let firstKeptSortOrder: Int
    /// Number of raw messages that were compacted. UI display only.
    let compactedCount: Int
    let createdAt: Date
    /// LEGACY: sort_order of the UI boundary message.
    /// Only used as fallback for divider positioning on legacy markers.
    let uiBoundarySortOrder: Int?
    /// LEGACY: DB message ID of the boundary message (pre-Phase A name for firstKeptMessageId).
    /// Kept for cross-device sync compatibility with older builds.
    let boundaryMessageId: String?
    /// PRIMARY: DB message ID of the first kept (active-region) message.
    /// All restore / compact logic resolves boundaries through this id.
    /// Optional only for legacy markers written before Phase A.
    let firstKeptMessageId: String?
    /// PRIMARY: DB message ID of the last compacted message (right edge of the
    /// compacted range). Used by prune protection to avoid deleting marker anchors.
    /// Optional only for legacy markers written before Phase A.
    let lastCompactedMessageId: String?
    /// Marker schema version. 1 = legacy multi-field model (firstKept/boundary/
    /// sortOrder fallback chain). 2 = simplified id-only model: only
    /// `lastCompactedMessageId` is authoritative; everything before it (incl.)
    /// is the compacted range, everything after it is "live anchor + new msgs".
    /// `compactedCount` and `summary` are still meaningful for UI; all other
    /// columns are ignored for v2 markers.
    var version: Int = 1
}

/// Token usage stats stored with a message.
struct StoredTokenUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var latestContextTokens: Int?
}

/// A single message in the conversation (one "turn").
struct RawMessage: Identifiable, Codable, Hashable {
    let id: String
    let sessionId: String
    let role: MessageRole
    let parts: [ContentPart]
    let createdAt: Date
    var tokenUsage: StoredTokenUsage?
    /// Reasoning content from thinking models (Kimi, DeepSeek, QwQ, etc.) — must be echoed back.
    var reasoningContent: String?
    /// Number of mid-stream auto-retries that occurred before this message completed successfully.
    /// 0 means no interruption. Persisted to DB for display after session reload.
    var streamInterruptCount: Int = 0
    /// Database sort_order value. Populated during loadMessages, used for compact boundary tracking.
    var sortOrder: Int = 0
    /// [T-error-persist-ios] Device-local error string for a failed assistant
    /// turn. Mirrors ChatMessage.error; persisted to the messages.error_info
    /// column so the error indicator survives reload. nil = no error.
    var errorInfo: String? = nil
    /// [Fix v1.14.30] 远端回合的 clientMessageId（客户端生成、随 input 上行，
    /// bridge 原样写进历史条目并在回放时带回）。用于校准期把"本地 live 行"
    /// 与"bridge 回放行"按**协议身份**对上——不再靠正文猜测（附件/纯图片/
    /// 重复文本都会猜错）。设备本地语义：不进 iCloud 同步载荷，本地 agent
    /// 行恒 nil。
    var clientMessageId: String? = nil

    /// [Fix v1.14.33] 本行归属的**远端回合键**（= 该回合 user 输入的
    /// clientMessageId）。
    ///
    /// 重复渲染的病根：live 聚合行（1 行 N parts）与服务端回放行（N 行各
    /// 1 part）粒度不同，任何逐行 uuid/正文对账都配不上。回合键把"这条
    /// live 行是哪一轮对话的临时占位"变成**查表**——回合被服务端承载且已
    /// 终结 ⇒ live 行是冗余副本 ⇒ 吸收删除
    /// （见 `RemoteTurnModel.shouldAbsorb` / `RemoteTurnReconciler`）。
    ///
    /// device-local 语义（与 clientMessageId 一致）：本地 agent 行恒 nil，
    /// 不进 iCloud 同步载荷。nil = 本列新增前的老数据 —— 不阻塞自愈：
    /// `RemoteHistoryRepair` 用内容覆盖匹配兜底。
    var remoteTurnKey: String? = nil

    /// [T-token-attribution-snapshot] The model that ACTUALLY produced this
    /// message, snapshotted when it was written.
    ///
    /// Snapshot rather than a reference to resolve later: usage is a record of
    /// what happened, and it must not change when the configuration it once
    /// pointed at changes. `modelDisplayName` / `providerType` travel with the
    /// id so a deleted provider does not make history unreadable.
    ///
    /// nil on rows written before these columns existed — the signal the Usage
    /// page uses to mark a row estimated rather than measured.
    var modelId: String? = nil
    var modelDisplayName: String? = nil
    /// `ProviderType` **rawValue** (e.g. `openAI`), never a display name.
    var providerType: String? = nil
    /// Diagnostics / disambiguation only; the UI never resolves through it.
    var providerInstanceId: String? = nil

    /// [stable history ids · C6] 换 id 的浅拷贝 helper。
    ///
    /// 稳定身份路径下回放行的 id 由 `bm-{messageUuid}` 派生（`ReplayRowId`），
    /// 不能再沿用旧路径的 `bridge-{seq}` / `past-{...}` 形态。`id` 是 `let`，
    /// 故用复制构造。其余字段（含 `sortOrder`）原样保留——排序号由
    /// `applyStableHistoryReplace` 按 plan 重写，此处不参与决策。
    func withId(_ newId: String) -> RawMessage {
        RawMessage(
            id: newId,
            sessionId: sessionId,
            role: role,
            parts: parts,
            createdAt: createdAt,
            tokenUsage: tokenUsage,
            reasoningContent: reasoningContent,
            streamInterruptCount: streamInterruptCount,
            sortOrder: sortOrder,
            errorInfo: errorInfo,
            clientMessageId: clientMessageId,
            remoteTurnKey: remoteTurnKey,
            modelId: modelId,
            modelDisplayName: modelDisplayName,
            providerType: providerType,
            providerInstanceId: providerInstanceId
        )
    }

    /// True if this message contains only tool results (no user text).
    /// These are internal agent loop messages that shouldn't render as user bubbles.
    var isToolResultOnly: Bool {
        role == .user && !parts.isEmpty && parts.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
    }

    /// [T-bridge-message-ui-leak] The internal assistant "bridge" row inserted
    /// when a queued user message interrupts a tool loop (#579): it exists
    /// purely to keep agentHistory role-alternation intact
    /// (…user(tool_result) → assistant(bridge) → user(queued)…) and must
    /// never render in the chat UI. Detected by content match rather than a
    /// schema flag: we generate this text verbatim, a content match also hides
    /// rows persisted by OLDER builds (a new column could not), and no
    /// DB/iCloud-sync wiring is needed.
    static let internalBridgeText =
        "(Interrupted mid-task by a new user message. Decide based on the new message and overall context whether the prior task should continue — do not forget or abandon it unless the user explicitly says to stop, or the new message makes clear it is no longer needed.)"

    /// Every bridge text this app has ever generated. A row persisted by an
    /// OLDER build carries the PREVIOUS wording; matching the current constant
    /// alone would fail and leak that row into the UI (the exact regression seen
    /// after the 2026-07-23 wording change, d2e111e9). Match against the full
    /// set so old and new persisted bridges are both recognized. Prefix-match
    /// (not equality) tolerates trailing-whitespace / normalization drift from
    /// DB round-trips.
    static let internalBridgeTexts: [String] = [
        internalBridgeText,
        // Pre-d2e111e9 wording.
        "(Interrupted mid-task to handle your new message. Will return to the prior task after.)",
    ]

    /// True when `text` is any known internal-bridge string. Shared by
    /// RawMessage and ChatMessage so every layer recognizes the same rows.
    static func isInternalBridgeText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return internalBridgeTexts.contains { trimmed == $0 }
    }

    var isInternalBridge: Bool {
        guard role == .assistant, parts.count == 1,
              case .text(let s) = parts[0] else { return false }
        return Self.isInternalBridgeText(s)
    }
}
