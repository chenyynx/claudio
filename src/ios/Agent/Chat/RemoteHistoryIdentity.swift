// RemoteHistoryIdentity — 回放行 ↔ 本地承载行的**身份对账**（[Fix v1.14.30]）。
//
// 为什么单独成模块：远端会话里同一条用户消息有两个化身——
//   · 本地 live 行（UUID，带图片/附件/解析产物）
//   · bridge 回放行（bridge-{ns}-{seg}-{seq}）
// 校准必须判定"这条回放行是否已有本地行承载"，判定错了就会重复渲染
// （两条气泡）或把本地行甩到会话末尾。判定必须基于**身份**而非内容猜测。
//
// 身份来源（按优先级）：
//   1. `clientMessageId` —— 协议保证：客户端发消息时生成、bridge 原样写进
//      历史条目（bridge `websocket.ts:3331-3340`），get_history / delta 回放
//      时原样带回（客户端 decoder 已解，`CCPocketProtocol.ServerMessage`）。
//   2. `toolUseId` —— 工具结果行天然唯一。
//   3. 归一化正文 + 队列式 occurrence 配对 —— **兜底**，仅服务两批数据：
//      v1.14.30 之前写入的老行（没有 clientMessageId 列）、不回传
//      clientMessageId 的旧 bridge。
//
// 认领语义：一条本地行只能被一条回放行认领（`claimedRowIds`），
// 优先级 clientMessageId → toolUseId → 文本；文本队列弹出时跳过已被认领的行，
// 保证"第 i 个同文本回放行 ↔ 第 i 个**未被占用**的本地行"。
//
// 纯函数（无 DB / actor / 网络），单测在 RemoteHistoryIdentityTests。

import Foundation

/// 一次校准内的配对索引。
struct RemoteHistoryOwnerIndex {

    /// clientMessageId → 本地行 id（clientMessageId 由发送方生成，天然唯一）
    private var byClientMessageId: [String: String] = [:]
    /// toolUseId → 本地行 id（工具结果行）
    private var byToolUseId: [String: String] = [:]
    /// 归一化正文 → 本地行 id 队列（同文本多 occurrence 按序配对）
    private var textQueues: [String: [String]] = [:]
    /// 已被认领的本地行 id（同一行不得被两条回放行占用）
    private var claimedRowIds: Set<String> = []

    /// 建索引。
    /// - Parameters:
    ///   - dbRows: 本地现有行（`ChatStore.loadMessages` 原样输出）
    ///   - deleteIds: 本轮将被删除的行 id——不得进池（否则本轮回放行会顶替
    ///     一个马上要被删的 id：旧行已删 + 新行不插 = 用户消息净丢）
    init(dbRows: [RawMessage], excluding deleteIds: Set<String>) {
        // ⚠️ 只收 **live 行**（UUID）——回放行（bridge-*/past-*）**不得进池**：
        // 它们本身就是回放产物，不是"本地承载行"；进池后会与真正的 live 行
        // 竞争同一个文本队列（队列按 sort_order 出队，回放行常常更靠前），
        // 把带附件/图片的 live 行挤成"无人认领" → 落进 after 桶甩到会话末尾
        // = 用户发言又被顶到最后（对抗审查 2026-09-11 构造实证）。
        // 回放行的"在位"由 planReplace 的 keep 分支按 id 负责，不需要 owner。
        for row in dbRows where row.role == .user
            && !deleteIds.contains(row.id)
            && !ReplayRowId.isReplayRow(row.id) {
            if case .toolResult(let tr) = row.parts.first {
                if byToolUseId[tr.toolUseId] == nil {
                    byToolUseId[tr.toolUseId] = row.id
                }
                continue
            }
            // 协议身份入索引（同一 clientMessageId 只认第一行）
            if let clientId = row.clientMessageId, !clientId.isEmpty, byClientMessageId[clientId] == nil {
                byClientMessageId[clientId] = row.id
            }
            // ⚠️ 文本队列**不因有 clientId 而排除本行**：bridge 端若未回传
            // clientMessageId（旧版 bridge / 上游），回放行只能走文本兜底——
            // 把这类行排除会让它们永远配不上（重复气泡，比 v1.14.29 还差）。
            // 已被 clientId 认领的行由 claimedRowIds 挡重复认领。
            guard let key = Self.textKey(parts: row.parts) else { continue }
            textQueues[key, default: []].append(row.id)
        }
    }

    /// 为一条回放行认领本地承载行；nil = 无本地行（调用方应正常插入该行）。
    mutating func claimOwner(for raw: RawMessage) -> String? {
        guard raw.role == .user else { return nil }

        // 1. clientMessageId（协议身份，首选）
        if let clientId = raw.clientMessageId, !clientId.isEmpty,
           let owner = byClientMessageId[clientId],
           claimedRowIds.insert(owner).inserted {
            return owner
        }

        // 2. toolUseId（工具结果行）
        if case .toolResult(let tr) = raw.parts.first, let owner = byToolUseId[tr.toolUseId] {
            guard claimedRowIds.insert(owner).inserted else { return nil }
            return owner
        }

        // 3. 配对键兜底（老行 / 无 clientMessageId 的 bridge）
        guard let key = Self.textKey(parts: raw.parts) else { return nil }
        guard var queue = textQueues[key], !queue.isEmpty else { return nil }
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if claimedRowIds.insert(candidate).inserted {
                textQueues[key] = queue
                return candidate
            }
        }
        textQueues[key] = []
        return nil
    }

    // MARK: - 内容键（兜底匹配用）

    /// 用户正文配对键：第一个「剥掉附件 XML 后非空」的 text part。
    /// 无文本部分（纯图片 / tool_result-only 行）→ nil（不参与文本配对，
    /// 这类行只能靠 clientMessageId 认领——v1.14.30 起协议会带回）。
    ///
    /// ⚠️ 参数类型是 **ContentPart**（`RawMessage` 的持久化 parts 类型），
    /// 不是 `AgentMessage` 的 `AgentContentPart`——两者是不同 enum，混用会
    /// 编译失败（v1.14.29 CI 实锤：cannot convert '[ContentPart]' to
    /// '[AgentContentPart]'）。本模块只处理已落库的 `RawMessage`。
    static func textKey(parts: [ContentPart]) -> String? {
        for part in parts {
            guard case .text(let raw) = part else { continue }
            let normalized = normalizedUserText(raw)
            if !normalized.isEmpty { return normalized }
        }
        return nil
    }

    /// 剥掉附件 XML 块后的用户正文。
    ///
    /// 本地行 parts = [xml, 正文]；bridge 端 user_input 文本 = "正文\n\n"+XML。
    /// 不归一化则两侧永远对不上（重复气泡 + 本地行被甩尾）。
    static func normalizedUserText(_ text: String) -> String {
        var s = removeBlocks(text, open: "<user-attached-files>", close: "</user-attached-files>")
        s = removeBlocks(s, open: "<attachment-failed", close: "/>")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 删除成对标记包住的整段（闭合标记缺失则放弃，避免死循环）。
    private static func removeBlocks(_ text: String, open: String, close: String) -> String {
        var s = text
        while let openRange = s.range(of: open) {
            let searchRange = openRange.upperBound..<s.endIndex
            guard let closeRange = s.range(of: close, range: searchRange) else { break }
            s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return s
    }
}
