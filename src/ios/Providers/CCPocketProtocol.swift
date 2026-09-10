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
        // [Claudio 2026-09-07 P2] 远端优先体验：resume 时把当前 defaults
        // 的 model/effort/fallbackModel 透传给桥，spawn 新进程立即生效。
        // 桥端 case "resume_session" 已收这三个字段（websocket.ts:5400+）。
        var model: String?
        var effort: String?
        var fallbackModel: String?
    }

    /// `interrupt` — stop the current turn; the agent responds with
    /// `result subtype=stopped`.
    struct InterruptRequest: Encodable {
        let type = "interrupt"
        var sessionId: String?
    }

    /// [Claudio 2026-09-05] `prepare_file_download` — request a one-shot
    /// download URL for a file the remote agent produced (e.g. via the Write
    /// tool). Mirrors ccpocket bridge `prepareFileDownload`
    /// (websocket.ts:1076-1205) which is the **upload** protocol's symmetric
    /// counterpart: the client asks for a tokenized URL, the bridge responds
    /// with `file_download_ready {downloadUrl, fileName, mimeType, sizeBytes,
    /// filePath}`, and the client HTTP-GETs the URL (no `finalize` step).
    ///
    /// `filePath` is **project-relative** (NOT absolute) — the bridge rejects
    /// absolute paths at websocket.ts:1082-1090 with `file_download_not_allowed`.
    /// App converts AssistantBlock.outputFileRemotePath (absolute) to relative
    /// before calling this.
    struct PrepareFileDownloadRequest: Encodable {
        let type = "prepare_file_download"
        var projectPath: String
        var filePath: String    // project-relative
        var requestId: String?
        var sessionId: String?
    }

    /// [Claudio 2026-09-05] Canonical error codes from ccpocket's
    /// `prepareFileDownload` (websocket.ts:1055-1074). Mirrored verbatim so
    /// App-side error handling can switch on the same enum rather than parse
    /// raw strings. Distinct from upload error codes by `_download_` prefix.
    enum FileDownloadErrorCode: String, Sendable {
        case notAllowed    = "file_download_not_allowed"   // path outside project / symlink escape / absolute path
        case notFound      = "file_download_not_found"     // realpath failed
        case notFile       = "file_download_not_file"      // not a regular file
        case tooLarge      = "file_download_too_large"     // > bridge.fileDownloadMaxBytes
        case unavailable   = "file_download_unavailable"  // bridge has no mediaStore
        case failed        = "file_download_failed"        // catch-all during register
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

    /// [增量恢复 v1.14.23] `get_history_delta` 请求（官方 websocket.ts:5054
    /// Claude/Codex 同款）。sinceSeq 语义见 bridge session.ts:774
    /// getHistorySince：返回 seq > sinceSeq 的增量；cursor 落后 trim 窗口
    /// → kind=snapshot；cursor 恰好= 全部 → 空 delta。
    struct GetHistoryDeltaRequest: Encodable {
        let type = "get_history_delta"
        var sessionId: String
        var sinceSeq: Int
    }

    // MARK: - File Peek (text/image/media) — ccpocket file_peek protocol
    //
    // 桥端三段式 RPC:list_files 拿文件列表 + read_file 读文本/小图 +
    // read_media_file 读音视频(mediaUrl 流式)。对齐 ccpocket 官方
    // bridge/parser.ts:278-316 + apps/mobile/lib/models/messages.dart
    // ClientMessage.readFile/readMediaFile/listFiles 工厂。
    //
    // 调用方式:build payload → CCPocketClient.sendAndWaitRPC →
    // 桥走 rpcWaiters 配对(CCPocketClient.swift:640-670)返回 file_list /
    // file_content 响应。

    /// `list_files` — 列出项目内所有可预览的文件(websocket.ts:6147)。
    /// 返回 file_list 消息(files/ignored/modifiedAt/totalFiles/truncated)。
    struct ListFilesRequest: Encodable {
        let type = "list_files"
        var projectPath: String
        var requestId: String?
    }

    /// `read_file` — 读文本/代码/Markdown/HTML 文本内容,或 ≤5MB 图片 base64
    /// 内联(websocket.ts:5930-6108)。maxLines 控制文本截断(默认 5000)。
    /// 大于 5MB 的图片会报 file_content error="Image too large" → App
    /// 端对齐 ccpocket 报"Image too large (max 5MB)",真要看大图走
    /// 9a844c3 的 prepare_file_download 完整下载。
    struct ReadFileRequest: Encodable {
        let type = "read_file"
        var projectPath: String
        var filePath: String
        var maxLines: Int?
        var requestId: String?
    }

    /// `read_media_file` — 读音视频,桥 mediaStore.register 注册后返回
    /// HTTP mediaUrl 相对路径 `/api/media/<id>`(media-store.ts:143)，
    /// App 端拼上 httpBaseUrl 即可 AVPlayer 流式播放。
    struct ReadMediaFileRequest: Encodable {
        let type = "read_media_file"
        var projectPath: String
        var filePath: String
        var requestId: String?
    }

    // MARK: - File Peek responses (file_list / file_content)

    /// `file_list` 响应。ccpocket 桥的 list_files 分支回包。
    /// files = 完整路径列表(项目内相对路径);ignored = 跳过的文件
    /// (如大文件、binary);modifiedAt = path → mtime(秒);
    /// totalFiles/truncated = 是否有上限截断(maxEntries/maxBytes)。
    /// all-optional 保持 lenient parse 兼容旧桥。
    ///
    /// [Claudio 2026-09-06] `ignored` 字段类型修正：桥端
    /// (claudio-bridge packages/bridge/src/git-operations.ts:ClientFileListResult)
    /// 实际返回 `ignored: boolean[]`（与 files 等长，标记每个文件是否被
    /// git 忽略），iOS 之前定义成 `[String]?` 会让 JSONDecoder 抛
    /// typeMismatch → RemoteProjectFileIndex.refresh 走 catch →
    /// suffixSet 永远 nil → 反引号内/裸路径识别失效。改 [Bool]? 对齐
    /// wire format。iOS 端不消费此字段（ccpocket 客户端也只解析成
    /// Set<String> 然后丢弃），保留只为 decode 不报错。
    struct FileListResponse: Decodable {
        let files: [String]?
        let ignored: [Bool]?
        let modifiedAt: [String: Double]?
        let totalFiles: Int?
        let truncated: Bool?
        let error: String?
    }

    /// `file_content` 响应。read_file/read_media_file 共用回包,按
    /// `kind` 字段路由:
    ///   - "text"   → content 字符串 + language + totalLines + truncated
    ///   - "image"  → base64 内联 + mimeType + sizeBytes(≤5MB)
    ///   - "audio"  → mediaUrl 相对路径 + mimeType + sizeBytes
    ///   - "video"  → mediaUrl 相对路径 + mimeType + sizeBytes
    /// error 非空表示失败(Image too large / Path not allowed / File not
    /// found 等,见 websocket.ts:5930-6085 各种 case)。
    struct FileContentResponse: Decodable {
        let kind: String?       // "text" | "image" | "audio" | "video"
        let content: String?    // text only
        let language: String?   // text only
        let totalLines: Int?    // text only
        let truncated: Bool?    // text only
        let base64: String?     // image only
        let mimeType: String?   // image/audio/video
        let sizeBytes: Int64?   // image/audio/video
        let mediaUrl: String?   // audio/video
        let filePath: String?   // echoed back from request
        let error: String?
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
        // bridge status events (`type:"status"` carries `status`; the
        // Bridge relays the SDK's compact_boundary as status="compacting"
        // — the only compaction signal the app receives. No end event
        // exists on the wire.)
        let status: String?
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
        // Cache accounting — Anthropic result payloads carry both
        // cache_creation_input_tokens (bytes written to the prompt cache
        // this turn) and cache_read_input_tokens (cache hits). The bridge
        // bridge/sdk-process.ts:extractTokenUsage parses both and rides
        // them on the result tokenUsage spread; without these fields the
        // remote Token Usage sheet shows zero for cache read/write. Wire
        // field names are camelCase, matching the bridge output.
        let cacheCreationInputTokens: Int?
        let cachedInputTokens: Int?
        let cost: Double?
        let duration: Double?
        let toolCalls: Int?
        // [C-5.5 修复 2026-09-10] past_history 的消息是磁盘 jsonl 的 raw
        // Claude API 格式：{role: "user"/"assistant", content: [blocks]}——
        // 没有 type/type 字段（bridge/websocket.ts splitPastHistoryMessages
        // 原样透传）。没有这两个字段时解码器把 content 数组整个丢弃 →
        // 历史恢复丢全部磁盘消息（resume 场景 + bridge 会话切换场景的
        // "会话窗断裂"根因）。tool_result 的 raw 形态走既有
        // toolUseId/content 字段，无需额外字段。
        let rawRole: String?
        // Wire 上的 `content` 是多态字段：tool_result 消息里是字符串（工具
        // 输出），past_history 的磁盘 raw 消息里是块数组（{role, content} 的
        // Claude API 格式）。两个形态共用同一个 wire key，但 ServerMessage
        // 的 CodingKeys 不能给两个 case 指定同一个 raw value（编译错
        // "raw value for enum case is not unique"，CI 34398320242）——
        // 也没有办法让合成的 decodeIfPresent 对同一个 key 按类型分流。
        // 解法：手写 init(from:) 从 key "content" 解码并按形态分流（见下）。
        let rawContentBlocks: [AssistantContentBlock]?

        private enum CodingKeys: String, CodingKey {
            case type, status, subtype, model
            case provider, projectPath, sessionId, claudeSessionId
            case permissionMode, message, text, toolUseId
            case content, toolName, permissionOutcome, input
            case result, error, stopReason, inputTokens
            case outputTokens, cacheCreationInputTokens, cachedInputTokens, cost
            case duration, toolCalls, messages, pastMessages
            case fromSeq, toSeq, reason, entries
            case sessions, hasMore, sourceSessionId, resumeRequestId
            case acceptedSeq, queued, historySeq, errorCode
            case requestId, userMessageUuid, clientMessageId, baseSeq
            case skills, skillMetadata, claudeModels, claudeModelEfforts
            case codexModels, codexModelReasoningEfforts, codexModelServiceTiers, codexProfiles
            case defaultCodexProfile, allowedDirs
            // [C-5.5 修复] rawRole 映射 wire key "role"（磁盘 raw 消息）。
            // rawContentBlocks 不能在这里声明——"content" 已被上面的
            // case content 占用（raw value 冲突），改为 init(from:) 里
            // 手动解码（见下）。
            case rawRole = "role"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            subtype = try c.decodeIfPresent(String.self, forKey: .subtype)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            provider = try c.decodeIfPresent(String.self, forKey: .provider)
            projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
            claudeSessionId = try c.decodeIfPresent(String.self, forKey: .claudeSessionId)
            permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
            message = try c.decodeIfPresent(MessagePayload.self, forKey: .message)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            toolUseId = try c.decodeIfPresent(String.self, forKey: .toolUseId)
            toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
            permissionOutcome = try c.decodeIfPresent(String.self, forKey: .permissionOutcome)
            input = try c.decodeIfPresent([String: JSONValue].self, forKey: .input)
            result = try c.decodeIfPresent(String.self, forKey: .result)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
            inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
            outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
            cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
            cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
            cost = try c.decodeIfPresent(Double.self, forKey: .cost)
            duration = try c.decodeIfPresent(Double.self, forKey: .duration)
            toolCalls = try c.decodeIfPresent(Int.self, forKey: .toolCalls)
            fromSeq = try c.decodeIfPresent(Int.self, forKey: .fromSeq)
            toSeq = try c.decodeIfPresent(Int.self, forKey: .toSeq)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            entries = try c.decodeIfPresent([HistoryEntry].self, forKey: .entries)
            sessions = try c.decodeIfPresent([ServerSession].self, forKey: .sessions)
            hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore)
            sourceSessionId = try c.decodeIfPresent(String.self, forKey: .sourceSessionId)
            resumeRequestId = try c.decodeIfPresent(String.self, forKey: .resumeRequestId)
            acceptedSeq = try c.decodeIfPresent(Int.self, forKey: .acceptedSeq)
            queued = try c.decodeIfPresent(Bool.self, forKey: .queued)
            historySeq = try c.decodeIfPresent(Int.self, forKey: .historySeq)
            errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
            requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
            userMessageUuid = try c.decodeIfPresent(String.self, forKey: .userMessageUuid)
            clientMessageId = try c.decodeIfPresent(String.self, forKey: .clientMessageId)
            baseSeq = try c.decodeIfPresent(Int.self, forKey: .baseSeq)
            skills = try c.decodeIfPresent([String].self, forKey: .skills)
            skillMetadata = try c.decodeIfPresent([[String: JSONValue]].self, forKey: .skillMetadata)
            claudeModels = try c.decodeIfPresent([String].self, forKey: .claudeModels)
            claudeModelEfforts = try c.decodeIfPresent([String: [String]].self, forKey: .claudeModelEfforts)
            codexModels = try c.decodeIfPresent([String].self, forKey: .codexModels)
            codexModelReasoningEfforts = try c.decodeIfPresent([String: [String]].self, forKey: .codexModelReasoningEfforts)
            codexModelServiceTiers = try c.decodeIfPresent([String: [String]].self, forKey: .codexModelServiceTiers)
            codexProfiles = try c.decodeIfPresent([String].self, forKey: .codexProfiles)
            defaultCodexProfile = try c.decodeIfPresent(String.self, forKey: .defaultCodexProfile)
            allowedDirs = try c.decodeIfPresent([String].self, forKey: .allowedDirs)
            pastMessages = try c.decodeIfPresent([ServerMessage].self, forKey: .pastMessages)
            rawRole = try c.decodeIfPresent(String.self, forKey: .rawRole)

            // [增量恢复 v1.14.23] `messages` key 多态分流（第二处多态，与
            // content 分流同模式）：get_history_delta / history_snapshot 的
            // Claude 分支信封 messages = HistoryEntry[]（[{seq,message}]），
            // 全量 get_history 是 flat [ServerMessage]。⚠️ 不能用"先试 flat
            // 失败再试 entries"——ServerMessage 字段全 optional，entry 形态
            // 的 {"seq":2,"message":{...}} 会被**静默解码成全 nil 空壳**
            // （seq 丢弃、message 撞 MessagePayload?→unknown）而非抛
            // typeMismatch，try? 不触发 → delta 消息全丢。正确做法：先用
            // [JSONValue] 探测原始形态（首元素含 seq+message 键 = entry
            // 形态），再按已知形态解码。
            // [CI 34474439182 修复] messages 只能初始化一次——上面的合成
            // 序列里已有一行无条件解码（v1.14.19 遗留），此处分支内再赋值
            // = double init 编译错。删原行，分支内唯一赋值。
            if let rawShape = try? c.decodeIfPresent([JSONValue].self, forKey: .messages),
               !rawShape.isEmpty,
               case .object(let first) = rawShape[0],
               first["seq"] != nil, first["message"] != nil {
                messages = nil
                deltaEntries = try? c.decodeIfPresent([HistoryEntry].self, forKey: .messages)
            } else {
                messages = try? c.decodeIfPresent([ServerMessage].self, forKey: .messages)
                deltaEntries = nil
            }

            // [C-5.5] wire `content` 多态分流：字符串 = tool_result 工具输出
            // （既有语义），数组 = past_history 磁盘 raw 消息的内容块。
            // 直接对 .content 解码 [AssistantContentBlock] 会在 tool_result
            // 消息上抛 typeMismatch 炸掉整条消息——所以先试探字符串。
            if let s = try? c.decodeIfPresent(String.self, forKey: .content) {
                content = s
                rawContentBlocks = nil
            } else {
                content = nil
                rawContentBlocks = try? c.decodeIfPresent([AssistantContentBlock].self, forKey: .content)
            }
        }

        // history / past_history payload — bridge sends TWO sequential
        // messages: past_history (disk-resident history from resume), then
        // history (in-memory accumulated since session start). The entries[]
        // form (history_snapshot/delta) is Codex-specific. Claude provider
        // sends messages[] and pastMessages[].  all-optional for lenient
        // parse so old bridges still work.
        let messages: [ServerMessage]?
        let pastMessages: [ServerMessage]?
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
        // session_list 携带的远端可用模型清单(官方 websocket.ts:7780+
        // 每次 session_list 广播都带)。claudio 端负责消费
        // → RemoteModelCatalog，UI 层据此渲染 Model 下拉 + Effort
        // chip 联动。all-optional 保持 lenient parse 兼容旧桥。
        let claudeModels: [String]?
        let claudeModelEfforts: [String: [String]]?
        let codexModels: [String]?
        let codexModelReasoningEfforts: [String: [String]]?
        let codexModelServiceTiers: [String: [String]]?
        let codexProfiles: [String]?
        let defaultCodexProfile: String?
        // [Claudio 2026-09-06 G2] Bridge-side `BRIDGE_ALLOWED_DIRS` 白名单
        // (websocket.ts:7880/7923 — already exposed in session_list by upstream
        // and local fork). iOS parses this so RemoteAgentSetupView can
        // auto-fill Project Path with the first allowed directory (multi-user
        // principle: never hardcode a default like /home/ubuntu).
        let allowedDirs: [String]?
        // [增量恢复 v1.14.23 Phase 2] get_history_delta / history_snapshot
        // （Claude 分支）的 messages 字段是 HistoryEntry[]（[{seq,message}]，
        // websocket.ts:5062），与全量 get_history 的 flat [ServerMessage]
        // 同名不同形——手写 init(from:) 对 .messages key 先试 flat 再试
        // entries 形态，命中后者落到本字段。Codex 老桥的 history_snapshot
        // 是 flat 形态（走 messages 字段），两者互斥不冲突。
        let deltaEntries: [HistoryEntry]?
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
        /// Anthropic's thinking blocks store their content under the
        /// `thinking` key (NOT `text`).  Without this field the decoder
        /// silently drops the thinking content → reasoningContent stays
        /// empty → backfill from bridge history loses all thinking.
        let thinking: String?
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
