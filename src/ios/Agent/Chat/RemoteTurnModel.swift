// RemoteTurnModel — 远端会话的**回合模型**（[Fix v1.14.33] 重复渲染根治 · 模块 1/5）。
//
// 为什么需要"回合"这一层（重复渲染的病根）：
// 远端会话同一条消息有两个化身——
//   · live 行：本地流式落库，**一个回合一行、N 个 parts**（正文/思考/工具调用/结果全在这一行）
//   · 服务端行：bridge history 回放，**一个 part 一行**（`bm-{messageUuid}`）
// 两者身份不同（本地 UUID vs bm-）、粒度不同（1:N），**任何按 uuid/正文的
// 逐行对账都不可能把一行 8 parts 与 8 行 1 part 判为同一条消息**——于是每个
// 完成的回合都在 DB 里留下两份（pp 真机 2026-09-13 00:06 日志实锤：
// `B274A31B` 的 8 个 part 与 `bm-a3114…bm-0a762` 逐 part 对应）。
//
// 回合模型把"这条消息属于哪一轮对话"变成**可判定**的问题：
//   · 回合边界 = user 输入行（tool_result 回放行 role 也是 user，但不是边界）
//   · 回合键   = 该回合 user 输入的 clientMessageId（桥保证原样回传，
//                `bridge/session.ts` mergeUserInputIntoHistory）；
//                老会话无 cmid → 退化为 `turn@{首行 id}`
//   · live 行在落库时带 `remoteTurnKey`，于是"哪条 live 行是这个回合的临时
//     占位"变成查表，而不是猜。
//
// 纯函数（无 DB / actor / 网络），单测在 RemoteTurnModelTests。

import Foundation

/// 远端会话的一个回合：一条用户输入 + 其后直到下一条用户输入之前的全部服务端行。
struct RemoteTurn: Equatable {
    /// 回合键（clientMessageId，或老数据的 `turn@{锚点}` 退化键）
    let key: String
    /// 本回合的服务端承载行 id（`bm-` / `bridge-`，按服务端序）
    var serverRowIds: [String]
    /// 是否被服务端"终结"：其后已开始新回合，或本次快照末条是终态帧（result/status）。
    /// 未终结 = 回合仍在进行中 → live 行不得吸收（否则流式内容瞬间消失）。
    var isFinished: Bool
    /// 本回合的服务端行里**非回合边界**（非 user 输入）的行数。
    ///
    /// ⚠️ 为什么必须单独记：判定"回合已被服务端承载"时**不能**只看
    /// `serverRowIds.isEmpty`。user 输入行本身也是服务端行——若该回合只有
    /// user 输入行（助手帧尚未回放 / 被 trim / 用户发完就停），
    /// `serverRowIds` 非空但**助手内容一条都没有**，此时吸收 live 聚合行
    /// = 用户看到"提问没有回答"且不可逆（DB 已删，服务端也没内容补位）。
    var nonBoundaryRowCount: Int = 0

    /// 本回合是否已被服务端**内容**承载（至少一条非边界行 = 助手/工具内容）。
    ///
    /// 语义刻意收紧到"非边界行"而非"任意行"——见 `nonBoundaryRowCount` 注释。
    var isCarriedByServer: Bool { nonBoundaryRowCount > 0 }
}

enum RemoteTurnModel {

    /// 退化键前缀（无 clientMessageId 的老会话）。
    static let fallbackKeyPrefix = "turn@"
    /// 历史窗口从回合中间开始时的哨兵键（trim 窗口外属于更早的回合，不参与吸收）。
    static let headOrphanKey = "turn@head-orphan"

    /// 回合键：协议身份优先，退化键兜底。
    static func key(clientMessageId: String?, fallbackAnchor: String) -> String {
        if let cid = clientMessageId, !cid.isEmpty { return cid }
        return fallbackKeyPrefix + fallbackAnchor
    }

    /// user 输入边界判定。
    ///
    /// ⚠️ tool_result 回放行的 role 也是 `user`（桥把工具结果作为 user 消息
    /// 下发，见真机日志 `[6 user db=bridge-E tr=9865c]`）——它们**不是**回合
    /// 起点，必须靠 `isToolResultOnly` 排除，否则一个工具回合会被误切成 N 个回合
    /// （回合键退化 → 吸收判定失效 → 重复残留）。
    static func isUserInputBoundary(_ row: RawMessage) -> Bool {
        row.role == .user && !row.isToolResultOnly
    }

    /// 按 user 输入边界把**服务端行序列**切成回合（输入必须按服务端序）。
    ///
    /// - Parameters:
    ///   - rows: 本次快照的服务端行（已按服务端 seq 升序）
    ///   - lastTurnFinished: 末个回合是否已终结（由调用方按快照末条 wire type 判定，
    ///     见 `RemoteHistorySyncCore.isTurnInProgress`）
    static func splitServerTurns(_ rows: [RawMessage], lastTurnFinished: Bool) -> [RemoteTurn] {
        var turns: [RemoteTurn] = []
        for row in rows {
            if isUserInputBoundary(row) {
                turns.append(RemoteTurn(
                    key: key(clientMessageId: row.clientMessageId, fallbackAnchor: row.id),
                    serverRowIds: [row.id],
                    isFinished: false
                ))
                continue
            }
            if turns.isEmpty {
                // 窗口从回合中间开始（trim 掉了前面的 user 输入）：这一截属于
                // 窗口外更早的回合，用哨兵键承载——它不与任何 live 行的
                // turnKey 相等，故不会触发吸收（保守：宁可不删）。
                turns.append(RemoteTurn(
                    key: headOrphanKey, serverRowIds: [row.id],
                    isFinished: false, nonBoundaryRowCount: 1))
            } else {
                turns[turns.count - 1].serverRowIds.append(row.id)
                turns[turns.count - 1].nonBoundaryRowCount += 1
            }
        }
        guard !turns.isEmpty else { return turns }
        // 除末回合外，其后都有新的 user 输入 ⇒ 已终结。
        let lastIndex = turns.count - 1
        for index in 0..<lastIndex { turns[index].isFinished = true }
        turns[lastIndex].isFinished = lastTurnFinished
        return turns
    }

    /// live 行归属的回合下标（按显式 `remoteTurnKey` 查表）。
    ///
    /// 未知回合（老数据没有 turnKey）→ nil，调用方按"未知"处理（保守保留）。
    static func turnIndex(forLiveRow row: RawMessage, in turns: [RemoteTurn]) -> Int? {
        guard let turnKey = row.remoteTurnKey, !turnKey.isEmpty else { return nil }
        return turns.firstIndex { $0.key == turnKey }
    }

    /// live 行是否可被服务端承载行吸收（= 该行是冗余副本）。
    ///
    /// 三重保守条件（宁可不删、不多删）：
    /// 1. 行带显式 `remoteTurnKey` 且能定位到回合（无键 → 不吸收，交由
    ///    `RemoteHistoryRepair` 的内容覆盖匹配兜底）；
    /// 2. 该回合已有 ≥1 条服务端承载行（服务端还没有 = 本地是唯一副本）；
    /// 3. 该回合已终结（进行中的回合：live 行是流式内容的唯一来源）。
    ///
    /// 另有一条硬否决：行携带设备本地错误（`errorInfo`）时永不吸收——它
    /// 是这次失败的**唯一记录**，服务端不会有对应内容。
    ///
    /// user 行恒不吸收：本地 user 行携带附件 XML / 解析产物，服务端副本信息
    /// 更少（保留策略与 `planReplace` 一致），其重复由 `RemoteHistoryOwnerIndex`
    /// 在插入侧拦截。
    static func shouldAbsorb(liveRow row: RawMessage, in turns: [RemoteTurn]) -> Bool {
        guard row.role != .user else { return false }
        guard row.errorInfo == nil else { return false }
        guard let index = turnIndex(forLiveRow: row, in: turns) else { return false }
        let turn = turns[index]
        return turn.isCarriedByServer && turn.isFinished
    }
}

/// [T-ios-empty-turn-visible] 空回合成因。**纯判定**（无 AppLocalized / Logger 依赖），
/// 住在这里是因为本文件已 symlink 进 RemoteHistoryKit = 每次 push 真跑单测。
///
/// 设备侧拿得到的事实只有"本轮零内容 + 桥是否已收场 + 上下文占用 + 本轮输出
/// token"，成因是在这几项上做分档，不是断言上游到底发生了什么 —— 文案措辞
/// 因此一律带"可能"，避免把推断当结论（pp 定的纪律）。
public enum EmptyTurnCause: Equatable, Sendable {
    /// 上下文占用过高：空回复多半是溢出症状，盲重试无效，应引导压缩/新会话。
    case contextNearlyFull(used: Int, window: Int)
    /// 上游一个输出 token 都没给：多为额度耗尽 / 限流 / 密钥被拒后网关回空包。
    case upstreamNoContent
    /// 有输出 token 却无可见内容（如只回了被丢弃的 reasoning/工具帧）：归因不明。
    case unknown
}

/// [T-ios-remote-stall-visible] 批4：远端"回合未收场且桥侧再无新内容"时，何时该向
/// 用户交代。**纯判定**（住这里 = symlink 进 RemoteHistoryKit，单测每次 push 真跑）。
///
/// 病根：`beginRemoteTurnWatchdog` 每 3s 轮询，只有 wire 尾变成 result/error 才停，
/// **没有放弃上限**；而 Retry 按钮挂在 `!isProcessing` 上 ⇒ 上游真停时用户面对的是
/// 无限 spinner + 无提示 + 点不到重试。
public enum RemoteTurnStallPolicy {
    /// 默认静默上限：4 分钟。取这个量级是因为远端合法的长工具（编译/CI 等待）也会
    /// 让桥侧零事件，阈值太低会把"仍在干活"误报成停滞。
    public static let defaultGiveUpSeconds: Double = 240

    /// `deadline <= 0` = 关断（逐字节回到现在的无限轮询行为，留的逃生阀）。
    /// 用 Double 而非 TimeInterval：本文件也编进 SwiftPM 包，不依赖 Foundation。
    /// （app 侧 TimeInterval 就是 Double，调用点无需转换。）
    public static func shouldGiveUp(elapsed: Double, deadline: Double) -> Bool {
        guard deadline > 0 else { return false }
        return elapsed >= deadline
    }
}

public enum EmptyTurnPolicy {
    /// 与既有内联阈值同源（0.7）。提到常量是为了单测能锁住边界。
    public static let contextPressureRatio = 0.7

    /// 优先级：上下文压力 > 零输出 > 未知。上下文满时即使 outputTokens=0，
    /// 用户可行动的处置也是"压缩/新会话"而不是"重试"，故先判它。
    /// `contextWindow <= 0`（模型窗口未知）时不做除法，直接跳到下一档。
    public static func cause(contextTokens: Int, contextWindow: Int, outputTokens: Int) -> EmptyTurnCause {
        if contextWindow > 0, Double(contextTokens) > Double(contextWindow) * contextPressureRatio {
            return .contextNearlyFull(used: contextTokens, window: contextWindow)
        }
        if outputTokens == 0 { return .upstreamNoContent }
        return .unknown
    }
}
