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
// [S1a 2026-09-14] 新增**回放池**（byReplayKey）：库内回放行（bm-/bridge-/past-）
// 的强身份（toolUseId/clientMessageId，键带 u:/r:/c: 前缀，不收文本键）也可被
// 认领，owner 为回放行 = 同一 wire 条目的**旧形态**（桥 gen→real 回填、两路
// 先后入库），Reconciler 据此做形态升级（插/留快照形态、删旧形态）。
// 优先级铁律：user 行 live 池（cmid/toolUseId）永远先于回放池——旧形态若抢在
// live 承载行前被命中，升级插入的新行会与 live 行双份（行为回退）。
// assistant 行原本直通 .unmatched，现仅探回放池（live 池不收 assistant 不变）。
//
// [v1.14.31] 超额副本判定：同批次里命中同一本地行的第 i+n 条回放行 =
// bridge 对同一逻辑消息的**超录**（watchdog 重试重发等）→ `.duplicate`
// 丢弃不插。旧 Optional 语义把"已占用"和"无本地行"都返回 nil → 超录行
// 被当新内容插成重复气泡（pp 真机 2026-09-11「你好」双气泡实锤）。
//
// 纯函数（无 DB / actor / 网络），单测在 RemoteHistoryIdentityTests。

import Foundation

/// 身份对账结果（v1.14.31）：bridge 回放行 vs 本地承载行的三种判定**必须**
/// 分开——旧 Optional 语义里"已被占用"与"无本地行"同为 nil，超录副本被
/// 当新内容插入。
enum OwnerClaim: Equatable {
    /// 成功认领一条未被占用的本地承载行 → 回放行由它承载（不插入），
    /// 本地行在 unified 序里顶替回放行的位置。
    case owner(String)
    /// 身份/文本命中的本地行已被本批更早的回放行占用 = 同一逻辑消息被
    /// bridge 超录（watchdog 重试重发等）→ 丢弃本条回放行，不插入。
    case duplicate
    /// 没有对应本地行（其他设备/老会话的新内容等）→ 照常插入。
    case unmatched
}

/// 一次校准内的配对索引。
struct RemoteHistoryOwnerIndex {

    /// clientMessageId → 本地行 id（clientMessageId 由发送方生成，天然唯一）
    private var byClientMessageId: [String: String] = [:]
    /// toolUseId → 本地行 id（工具结果行）
    private var byToolUseId: [String: String] = [:]
    /// 归一化正文 → 本地行 id 队列（同文本多 occurrence 按序配对）
    private var textQueues: [String: [String]] = [:]
    /// [S1a] 强身份 → **回放行** id（形态互认池）。同一条 wire 条目可能以两种
    /// 主键先后入库（桥 gen→real 回填、delta 先落 bm-{G} 快照后带 bm-{R}），
    /// 主键变了但 parts 里的强身份（toolUseId / clientMessageId）同源 ——
    /// 回放池让旧形态可被认领，Reconciler 据此做「形态升级」：权威形态存活、
    /// 旧形态删除。必须升级而非保留旧形态：桥后续只发新形态 id，旧形态会
    /// 永久 miss `serverIdSet` 判定 → headRows 甩头（本次乱序的机制本体）。
    /// ⚠️ 只收强身份、**不收文本队列**：内容级配对是仓库明文否决的
    /// （09-11 对抗实证：回放行与 live 行竞争文本队列会挤掉 live 行甩尾）；
    /// toolUseId 是 UUID 级唯一、无竞争面。live 池命中永远优先（user 行）。
    private var byReplayKey: [String: String] = [:]
    /// [S1a] 回放池开关。**只有新路径（RemoteTurnReconciler）开启**：
    /// 旧路径 planStableReplace（v1.14.32 回滚通道，SyncCore 调用）必须逐字节
    /// 保持旧行为，否则"回滚 = 还原 v1.14.32"的语义被破坏（死隔离 gate）。
    private let formUpgradePoolEnabled: Bool
    /// 已被认领的本地行 id（同一行不得被两条回放行占用）
    private var claimedRowIds: Set<String> = []

    /// 建索引。
    /// - Parameters:
    ///   - dbRows: 本地现有行（`ChatStore.loadMessages` 原样输出）
    ///   - deleteIds: 本轮将被删除的行 id——不得进池（否则本轮回放行会顶替
    ///     一个马上要被删的 id：旧行已删 + 新行不插 = 用户消息净丢）
    ///   - formUpgradePool: [S1a] 是否开启回放池（旧形态互认）。默认关——
    ///     仅新路径 RemoteTurnReconciler 显式传 true，回滚通道保持 v1.14.32 行为。
    init(dbRows: [RawMessage], excluding deleteIds: Set<String>,
         formUpgradePool: Bool = false) {
        formUpgradePoolEnabled = formUpgradePool
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
        // [S1a] 第二遍：回放行进强身份池（不碰文本队列，理由见字段注释）。
        // 排在 live 池之后 + `??=` 只填空键 ⇒ 同一强身份 live 承载行永远优先，
        // 回放池仅做「旧形态互认」，不抢 live 行的认领权。
        if formUpgradePoolEnabled {
            for row in dbRows where ReplayRowId.isReplayRow(row.id)
                && !deleteIds.contains(row.id) {
                for key in Self.strongKeys(of: row) {
                    byReplayKey[key] = byReplayKey[key] ?? row.id
                }
            }
        }
    }

    /// 为一条回放行认领本地承载行（结果语义见 OwnerClaim）。
    /// "命中即消费一次"——保证第 i 个回放行对上第 i 个**未被占用**的本地行；
    /// 超额命中（第 i+n 条）返回 .duplicate 而不是当新内容插入（v1.14.31 F1）。
    mutating func claimOwner(for raw: RawMessage) -> OwnerClaim {
        // [S1a] 回放池探测（非己方旧形态）。**优先级按角色**：
        //   · assistant：直通回放池（live 池本就不收 assistant，无竞争）；
        //   · user：live 三步池（cmid/toolUseId）优先——若旧形态 G 先命中，
        //     升级插入的 R 会与 live 承载行 L 双份（丢 L 保 R 是行为回退）。
        // self 命中（同 id 重放）跳过走原分支，幂等承载。
        if formUpgradePoolEnabled, ReplayRowId.isReplayRow(raw.id) {
            if raw.role != .user {
                for key in Self.strongKeys(of: raw) {
                    guard let owner = byReplayKey[key], owner != raw.id else { continue }
                    return claimedRowIds.insert(owner).inserted ? .owner(owner) : .duplicate
                }
                return .unmatched
            }
            // user：先查 cmid / toolUseId 两个 live 池（peek 不消费），
            // 都未命中才看回放池（peek），再落原有三步（含文本兜底）。
            let liveHit = (raw.clientMessageId.flatMap { byClientMessageId[$0] })
                ?? (raw.parts.first.flatMap { part in
                    guard case .toolResult(let tr) = part else { return nil }
                    return byToolUseId[tr.toolUseId]
                })
            if liveHit == nil {
                for key in Self.strongKeys(of: raw) {
                    guard let owner = byReplayKey[key], owner != raw.id else { continue }
                    return claimedRowIds.insert(owner).inserted ? .owner(owner) : .duplicate
                }
            }
        }

        guard raw.role == .user else { return .unmatched }

        // 1. clientMessageId（协议身份，首选）
        if let clientId = raw.clientMessageId, !clientId.isEmpty,
           let owner = byClientMessageId[clientId] {
            return claimedRowIds.insert(owner).inserted ? .owner(owner) : .duplicate
        }

        // 2. toolUseId（工具结果行）
        if case .toolResult(let tr) = raw.parts.first, let owner = byToolUseId[tr.toolUseId] {
            return claimedRowIds.insert(owner).inserted ? .owner(owner) : .duplicate
        }

        // 3. 配对键兜底（老行 / 无 clientMessageId 的 bridge）
        guard let key = Self.textKey(parts: raw.parts) else { return .unmatched }
        guard textQueues[key] != nil else { return .unmatched }
        var queue = textQueues[key]!
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if claimedRowIds.insert(candidate).inserted {
                textQueues[key] = queue
                return .owner(candidate)
            }
        }
        textQueues[key] = []
        // 池里本有过该文本的本地行但已全部被占用 → 回放行数超出本地行数
        // = 超录副本，丢弃。
        return .duplicate
    }

    // MARK: - 内容键（兜底匹配用）

    /// [S1a] 一行的**强身份键**集合：clientMessageId + 全部 toolUse/toolResult
    /// 的 toolUseId。键带类型前缀（c:/u:/r:），与 `RemoteHistoryRepair.partKey`
    /// 同族语义但**不含文本/媒体键**——内容级配对在认领侧被明文否决，这里
    /// 只认 UUID 级身份。一行多个键全部入池（聚合行 1:N 承载时每个 call id
    /// 都能指回它）。
    static func strongKeys(of raw: RawMessage) -> [String] {
        var keys: [String] = []
        if let cid = raw.clientMessageId, !cid.isEmpty { keys.append("c:\(cid)") }
        for part in raw.parts {
            switch part {
            case .toolUse(let tu): keys.append("u:\(tu.toolUseId)")
            case .toolResult(let tr): keys.append("r:\(tr.toolUseId)")
            case .text, .mediaRef: break
            }
        }
        return keys
    }

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

// ═══════════════════════════════════════════════════════════════════
// [dup-drift fix 2026-09-14] wire 身份提升：userMessageUuid → messageUuid
//
// 桥的三种历史响应把**同一条 wire 条目**的稳定身份放在不同位置：
//   · history_delta / history_snapshot（entries 形态）→ 顶层 entry.messageUuid
//   · 全量 history（raw messages 形态，websocket.ts:5060 发 session.history）
//     → assistant 帧在 body.messageUuid，user_input / tool_result 帧在
//       body.userMessageUuid
// 而 iOS 下游消费链（historyAgentMessagesWithWire / rawMessageId）只读
// `messageUuid`。后果：同一条 tool_result 经 delta 落库为 `bm-{uuid}`、
// 经全量 history 落库为 `bridge-{ns}-{seg}-{seq}` —— 两个主键两份内容
// （dupContent 逐轮累加），且旧 bm- 行不在新快照 id 集里被"窗外旧行"
// 规则甩到列表最前（pp 真机 2026-09-14 07:36 乱序+dupContent=7 实锤）。
//
// 修复：扁平化层把 userMessageUuid 提升到 messageUuid（缺失才提升），
// 两条投递路径收敛到同一 `bm-{uuid}` 主键 → 重复投递 = 幂等 upsert。
// 纯函数（无 actor / 网络），单测在 RemoteHistoryIdentityTests。
// ═══════════════════════════════════════════════════════════════════
public enum WireUuidHoist {
    /// messageUuid 非空则原样胜出；否则非空 userMessageUuid 提升；都空 → nil。
    public static func hoist(messageUuid: String?, userMessageUuid: String?) -> String? {
        if let m = messageUuid, !m.isEmpty { return m }
        if let u = userMessageUuid, !u.isEmpty { return u }
        return nil
    }
}
