// RemoteHistorySyncCore — 远端会话恢复的校准计划纯函数（官方 replaceEntries 语义）。
//
// 背景（2026-09-10，v1.14.18）：此前的恢复链路依赖三套自创机制——
// RemoteSessionMetadata 水位、contentFingerprint 指纹、BackfillCore 增量判定。
// live 落库 id（UUID）与 bridge 回放 id（bridge-{seq}）是两套永不相交的标识
// 系统，水位只抬最终轮、tool_result 回放无 seq、指纹 prefix(3) 有盲区——
// 四个盲区叠加 = 杀后台重进乱序/重复/吞（见 Bug 经验库 Claudio 条目）。
//
// 本模块对齐官方（ccpocket get_history + replaceEntries，websocket.ts:3139）：
// bridge history 是唯一真相。给定 bridge history 转换出的 RawMessage 序列和
// 本地 DB 现有行，算出"校准计划"——保留什么、删除什么、插入什么。
//
// 保留规则：
// - user 行全保留（live 落库的用户消息，含附件 mediaRef、XML 解析结果等
//   本地增强；bridge 端 user_input 的图片等价信息少于本地行，换血反而丢数据）
//   ↳ 防双份（排查 2026-09-10）：bridge 回放的 user_input（bridge-{seq}）与
//     live 落库的同文本 user 行（UUID）并存 = 同一条用户消息渲染两次且
//     位置错乱（UUID 行按旧 sort_order 进保留区，回放行按 history 序）。
//     修法在 inserts 端：history 的 user 行若已有同文本本地行 → 不插入
//     （本地行保住图片+解析，bridge 行不重复落库；该 seq 每轮校准重复
//     判定一次 skip，幂等无膨胀）。
// - 非 user 行分两类：
//   · UUID 行（live 落库，id 非 "bridge-" 前缀）→ 删除，其内容已由
//     bridge-{seq} 行承载（同内容换血）
//   · bridge-{seq} 行 → 只增不删。⚠️ bridge 端 MAX_HISTORY_PER_SESSION=100
//     （session.ts:186 trimHistory），get_history 只返回尾部 100 条——
//     更早的 bridge-{seq} 行不在本次 history 集里，若按"不在集即删"的
//     教条 replaceEntries 处理，长会话的 assistant/tool_result 历史会被
//     永久吞掉（对抗审查 R1 实锤）。bridge 是增量的真相，本地是累积缓存。
//
// 纯函数：无 actor / DB / UI 依赖，可单测（RemoteHistoryBackfillTests）。

import Foundation

/// 一次校准的执行计划。由 `ChatStore.replaceRemoteHistory` 在单事务内执行。
struct RemoteHistoryReplacePlan {
    /// 需要插入的行（按 bridge history 顺序；sortOrder 由事务内显式赋值）
    let inserts: [RawMessage]
    /// 需要删除的 DB 行 id（live UUID 行 + 不在 history 集内的多余行）
    let deleteIds: [String]
    /// 保留的原行数（诊断用）
    let keptCount: Int
    /// 最终排序的 id 序列（bridge history 序，防双份被挡的回放 user 行位置
    /// 替换为承载同内容的本地行 id）。replaceRemoteHistory 用它 renumber
    /// sort_order——没有它，本地 user 行（UUID）不在 history 序列内，
    /// renumber 的"retained 排前"规则会把所有 user 行顶到最前 = 顺序大乱
    /// （pp 真机实锤 2026-09-10 07:06 日志：两个 user 气泡置顶、回复全在后）。
    let unifiedFinalOrderIds: [String]

    var isEmpty: Bool { inserts.isEmpty && deleteIds.isEmpty }
}

enum RemoteHistorySyncCore {

    /// 计算校准计划。
    ///
    /// - Parameters:
    ///   - historyRaws: bridge history 转换出的行（管线已 buildRaw，
    ///     assistant/tool_result 行 id = `bridge-{seq}`）
    ///   - dbRows: 本地 DB 现有行（`ChatStore.loadMessages` 原样输出，按
    ///     sort_order 升序）
    ///   - nonEngineSeqs: bridge history 中存在但**不转换**为 engine 消息的
    ///     seq 集合（result/status 等类型）。落在这些 seq 上的 DB 行必然是
    ///     错绑残留（live 曾把 result 的 seq 错注入 assistant 行）→ 删。
    ///     仅此集合内的 bridge 行可删——trim 窗口外的老行（seq 不在本次
    ///     history）依旧只增不删（R1 规则）。
    ///   - evictPastRows: [Fix 2026-09-11] past id 空间迁移模式。bridge 端
    ///     disk 解析补全 tool_result/thinking 后，past-{index} 序列重排
    ///     （同一会话 index 全变），旧残缺序列的 past 行与新序列同 id 不同
    ///     内容——id 命中 keep 会保留旧残缺行（修复失效）。CLIENT 在检测到
    ///     迁移未完成 + 全量 fetch 成功时传 true：本次全部 past 行进
    ///     deleteIds，同事务按新序列重插。日常路径恒 false（past 行只增不删）。
    static func planReplace(historyRaws: [RawMessage], dbRows: [RawMessage], nonEngineSeqs: Set<Int> = [], forceFullReshuffle: Bool = false, evictPastRows: Bool = false, currentSegment: String? = nil, previousSegment: String? = nil) -> RemoteHistoryReplacePlan {
        let dbIds = Set(dbRows.map { $0.id })

        // 删除③（seq 空间重置检测，优先级最高）：bridge-{seq} 的 seq 是
        // **per-bridge-session** 计数——resume/重启会 spawn 新 bridge 会话
        // （官方语义，注释见 CCPocketClient.reconnectNow），新会话从 seq=1
        // 重新计数。此时 DB 里旧空间的 bridge-1..N 与新空间的 bridge-1..M
        // 同 id 不同内容 → id 命中 keep 旧行 = 内容串台/重复渲染（pp 真机
        // 实锤：正文/卡片/思考块全部双份）。信号（确定性优先）：
        // · forceFullReshuffle = bridgeId 与上次同步不同（per-chat 存储）
        // · 兜底：DB bridge max seq > history max seq（短会话会漏——
        //   旧 3 行 vs 新 5 行不触发，真实翻车后补 bridgeId 主信号）
        // 重置 → 非 user 行全部换血到新空间（user 行 UUID 无前缀，
        // 由防双份两键挡回放重复）。
        // [Fix v1.14.29] 统一走 ReplayRowId：兼容 `bridge-{seq}`（旧）与
        // `bridge-{ns}-{seq}`（新；ns = 本地会话前 8 位，见 ReplayRowId）。
        func bridgeSeq(_ id: String) -> Int? { ReplayRowId.parseBridgeSeq(id) }
        // [Fix v1.14.30 / 对抗审查 A2] **段作用域**：seq 只在同一个 bridge
        // 会话（段）内单调。多段并存时（换过 bridge 会话；或同一 chat 被
        // iCloud 同步到另一台设备，各自持不同 bridge 会话）按 seq 直接比较
        // 就是跨段误判——会删掉别的设备/旧段的行，且删除会对端同步 → 对端
        // 校准又插回 → "删/回插乒乓"。
        //
        // 判据只对本设备**自己的段**生效；外来段的行任何删除规则都不碰：
        //   自己的段 = ①无段（更早形态，待迁移补段）②本次 fetch 的段
        //              ③上一个 bridge 会话的段（换会话瞬间的旧空间，已被
        //                本次全量覆盖 = 换血靶子）
        func segmentOf(_ id: String) -> String? { ReplayRowId.parseSegment(id) }
        func isOwnSegment(_ row: RawMessage) -> Bool {
            guard let seg = segmentOf(row.id) else { return true }
            if let currentSegment, seg == currentSegment { return true }
            if let previousSegment, seg == previousSegment { return true }
            return false
        }
        let dbBridgeSeqs = dbRows.compactMap { row -> Int? in
            guard row.role != .user, isOwnSegment(row) else { return nil }
            return bridgeSeq(row.id)
        }
        let historySeqs = historyRaws.compactMap { bridgeSeq($0.id) }
        // [对抗审查 A3] 只有"新 history 在**同 seq 也是 user 行**"时才敢删旧
        // 空间的回放 user 行——同 seq 不同角色说明两边不是同一轮对话（换过
        // claude 会话等），删了就真丢内容。
        let historyUserSeqs = Set(
            historyRaws.filter { $0.role == .user }.compactMap { bridgeSeq($0.id) }
        )
        // bridgeId 切换（sync 层传入）是确定性信号；长度启发式只是无
        // bridgeId 时的兜底（短会话 dbMax<=histMax 时漏判——真实翻车）。
        let seqSpaceReset = forceFullReshuffle || {
            if let dbMax = dbBridgeSeqs.max(), let histMax = historySeqs.max() {
                return dbMax > histMax
            }
            return false
        }()

        // 删除①：live 落库的非 user UUID 行（id 非 "bridge-"/"past-" 前缀）。
        // [对抗审查 R4 实锤 2026-09-10] past-{index} 行（C-5.5 磁盘历史回放）
        // 同样无 bridge- 前缀——旧规则会把它们当 live UUID 行删掉且不回插
        // （插入按 keptIds 去重，past 行保留在 keptIds → 命中跳过）→ 磁盘
        // 历史每次校准净丢失。past 行是回放产物，身份稳定（磁盘
        // append-only），必须与 bridge-{seq} 行同享"只增不删"，由 id 集
        // 去重。大一统行退役（v1.14.20）后 live 落库恒为 UUID，删除①的
        // 靶子只有真 UUID 行。
        // 删除②：错绑残留行——id=bridge-{seq} 但该 seq 的 wire 消息是
        //         result/status（不进 engine/historyRaws），此行内容与回放
        //         行重复且永远无法被 id 命中（排查 2026-09-10 实锤）。
        // 删除③：seq 空间重置 → 全部非 user bridge 行换血（见上）。
        // bridge-{seq} 行其余情况只增不删——trim 窗口外的老 seq 不在本次
        // history 集里，删了就是永久吞消息（R1 审查实锤）。
        let deleteIds = dbRows
            .filter { row in
                // [Fix 2026-09-11] past id 空间迁移（见参数注释）：迁移模式
                // 下 past 行全清（user role 的 past 行同样清——它们会被新
                // 序列同事务重插；命中本地 owner 则不插由 unified 序承接）。
                // 检查须先于 user 保留规则。
                if row.id.hasPrefix("past-") { return evictPastRows }
                // [对抗审查 A2] 外来段的行：任何删除规则都不碰（跨设备/旧来源
                // 的段，删了就是删别的设备的内容 + 回插乒乓）。
                if !isOwnSegment(row) { return false }
                if row.role == .user {
                    // [对抗审查 A3] 换会话（seq 空间重置）时，旧空间的回放
                    // user 行（无段/旧段）若同 seq 已被本次 history 覆盖 →
                    // 内容由新行或本地承载行承接，删除旧行。不删则它永久
                    // 占住该 seq（keep 命中）→ 新内容永不落库 + 用户发言
                    // 被甩到会话末尾（每次校准复现，幂等不会自愈）。
                    // 未被 history 覆盖的（trim 窗口外）保留——删了不回插
                    // = 净丢内容。
                    guard seqSpaceReset, let seq = bridgeSeq(row.id) else { return false }
                    return segmentOf(row.id) != currentSegment && historyUserSeqs.contains(seq)
                }
                // [对抗审查 R4 追加] past-{index} 行是磁盘历史回放（claude
                // 会话 append-only，序列跨 bridge 会话稳定）——seq 空间重置
                // 换血的靶子是旧 bridge 空间的 bridge-{seq}/UUID 行，past 行
                // 不属于任何 seq 空间，换血时必须保留（删了不回插：dbIds
                // 快照命中插入跳过 → 净删 = 磁盘历史丢失）。
                if seqSpaceReset { return true }
                if !row.id.hasPrefix("bridge-") { return true }
                guard let seq = bridgeSeq(row.id) else { return false }
                return nonEngineSeqs.contains(seq)
            }
            .map { $0.id }

        // 插入：history 中 DB 还没有的行（按 history 原序）。
        // [对抗审查 R4 模拟实锤 2026-09-10] 基准必须用"删除后存活的 id 集"
        // 而非删除前快照——seq 空间重置/bridgeId 切换场景：旧空间 bridge-1
        // 行被删、新空间 bridge-1 行（同 id 不同内容）若按删除前 dbIds 判定
        // 会被跳过 → 换血后内容丢失（test_seqSpaceReset 的期望与之矛盾，
        // 测试步骤挂起从未执行所以一直没暴露）。keptIds = dbIds − deleteIds。
        // [Fix 2026-09-11] deleteIdSet 提前定义：防双份 owner 池必须排除
        // 本轮将删除的行——past 迁移模式下 past user 行会进 deleteIds，若
        // 仍进池会把新序列的同文本行顶替成"旧行 id"（旧行已删 + 新行不插
        // = 用户消息净丢）。
        let deleteIdSet = Set(deleteIds)
        // [Fix v1.14.30] 身份对账交给独立模块 RemoteHistoryOwnerIndex：
        // 优先级 clientMessageId（协议身份）→ toolUseId → 归一化正文队列兜底。
        // 旧实现把这三件事按正文猜着内联在这里，附件消息（本地 parts=[xml,
        // 正文] vs bridge "正文+XML"）、纯图片消息（无正文）、重复文本都会猜错。
        var owners = RemoteHistoryOwnerIndex(dbRows: dbRows, excluding: deleteIdSet)
        let keptIds = dbIds.subtracting(deleteIdSet)
        var inserts: [RawMessage] = []
        var unifiedFinalOrderIds: [String] = []
        // [Fix v1.14.30] 已落库的回放 user 行若认领到本地承载行：由本地行顶替
        // 它的位置，并把这条多余的**回放 user 行**排进删除。否则会出现
        // "回放行占位 + 本地行无人认领 → 落 after 桶甩到会话末尾 + 同一内容
        // 两个气泡"（对抗审查 2026-09-11 构造实证；老 build 对附件消息按原文
        // 比对必然配不上，pp 的库里很可能已有这类重复行）。
        var redundantReplayUserRowIds: [String] = []
        for raw in historyRaws {
            // owner 判定必须在 keep 判断之前，且"命中即消费一次"——保证第 i 个
            // 回放行对上第 i 个**未被占用**的本地行。
            let localOwnerId = owners.claimOwner(for: raw)
            if keptIds.contains(raw.id) {
                if let owner = localOwnerId, owner != raw.id {
                    unifiedFinalOrderIds.append(owner)
                    redundantReplayUserRowIds.append(raw.id)
                } else {
                    unifiedFinalOrderIds.append(raw.id)
                }
                continue
            }
            if let owner = localOwnerId {
                // 防双份：回放 user 行不插，本地行顶替它在 bridge 序里的位置
                unifiedFinalOrderIds.append(owner)
                continue
            }
            unifiedFinalOrderIds.append(raw.id)
            inserts.append(raw)
        }

        // [Fix v1.14.30] 冗余回放 user 行（同内容已由本地承载行渲染）并入删除。
        // "user 行只增不删" 的初衷是防"删了不回插 = 内容净丢"；这里删的是
        // **重复副本**——内容由 localOwner 行承载且在 unified 序里占位，故安全。
        var seenDeleteIds = Set<String>()
        let allDeleteIds = (deleteIds + redundantReplayUserRowIds)
            .filter { seenDeleteIds.insert($0).inserted }
        let keptCount = dbRows.count - allDeleteIds.count
        return RemoteHistoryReplacePlan(
            inserts: inserts,
            deleteIds: allDeleteIds,
            keptCount: keptCount,
            unifiedFinalOrderIds: unifiedFinalOrderIds
        )
    }

    /// 校准事务的最终行序列（`ChatStore.replaceRemoteHistory` 第 3 步 renumber
    /// 的定序来源）。抽成纯函数以便单测——DB 事务本身依赖 sqlite，但
    /// "哪些行排前/排后"的规则是纯逻辑，pp 真机两轮乱序（07:06 user 气泡
    /// 置顶 / 09-11 "在吗"被甩到第一条）都栽在这里。
    ///
    /// 规则（三段拼接）：
    /// 1. `replayBefore` — 不在本次 history 序里的 bridge-{seq}/past-{index}
    ///    老回放行（trimHistory 100 条窗口外的幸存者，只增不删）→ 历史最早。
    /// 2. `unifiedFinalOrderIds` 序（bridge history + 防双份命中的本地行替换）
    ///    → 中段主体。缺行时用 finalOrder 里的同 id 行兜底。
    /// 3. `liveAfter` — 其余不在 history 序里的行（live UUID：用户刚发的
    ///    消息、流式未完 assistant 行；bridge history 尚未承载 = 语义最新）
    ///    → 排最后。旧规则把它们排最前 = 乱序复发根因（见 §3 注释）。
    ///
    /// 组内均保持传入顺序（caller 已按现有 sort_order 升序给 `retainedRows`），
    /// 不重排。
    static func orderedRowSequence(
        unifiedFinalOrderIds: [String],
        finalOrder: [RawMessage],
        retainedRows: [RawMessage],
        rowById: [String: RawMessage],
        segmentRanks: [String: Int] = [:]
    ) -> [RawMessage] {
        var before: [RawMessage] = []
        var after: [RawMessage] = []
        for row in retainedRows {
            // bridge-/past- 前缀 = 回放行（老历史，排前）；其余（live UUID）
            // = 本地新内容（排后）。前缀判定收敛到 ReplayRowId（[Fix v1.14.29]）。
            if ReplayRowId.isReplayRow(row.id) {
                before.append(row)
            } else {
                after.append(row)
            }
        }
        // [Fix v1.14.30] 段级定序：多段并存（换过 bridge 会话 / 多设备共享同一
        // chat 会话）时，回放区按 (段首见次序, seq) 排——先见到的段 = 更早的
        // 历史，同段内 seq 单调。past 行恒最先（磁盘历史早于任何 bridge 会话）。
        before = Self.sortedReplayRows(before, segmentRanks: segmentRanks)
        var sequence: [RawMessage] = before
        for id in unifiedFinalOrderIds {
            if let row = rowById[id] {
                sequence.append(row)
            } else if let fallback = finalOrder.first(where: { $0.id == id }) {
                sequence.append(fallback)
            }
        }
        sequence.append(contentsOf: after)
        return sequence
    }

    /// 判定 bridge history 末尾是否处于"turn 进行中"。
    ///
    /// bridge 端 result（turn 结束）会 append 进 history（session.ts:614）；
    /// 进行中的 turn 尾部是 assistant / tool_result / user_input（result
    /// 尚未产生）。用于恢复态 isProcessing 衔接（发送键 → 停止键）。
    ///
    /// - Parameter lastWireType: fetch 返回的最后一条 wire 消息 type
    ///   （`history` 信封内 messages[] 的末条；nil = 空 history → idle）
    static func isTurnInProgress(lastWireType: String?) -> Bool {
        guard let lastWireType else { return false }
        switch lastWireType {
        case "result", "error", "status":
            return false
        default:
            // assistant / tool_result / user_input / 其他未知类型 → 视为进行中
            return true
        }
    }

    // MARK: - 增量快路径准入（[Fix v1.14.29] 远端乱序根因 A 的闸门）

    /// delta 增量**只含本次新条目**，而 renumber 的定序契约要求**全量
    /// history 序**——把残缺序喂进 `planReplace` 会让 `unifiedFinalOrderIds`
    /// 只剩那几条新行，`orderedRowSequence` 于是把所有不在序里的 live UUID 行
    /// （= 用户自己的**全部**发言）判为"历史未承载的最新内容"排到末尾：
    ///
    ///   pp 真机 2026-09-11 08:06 日志：空 delta → renumber-only →
    ///   重进后 "你好"/"你什么模型" 落在会话最末（[6]/[7]）。
    ///
    /// 因此 delta 只在**顺序已被一次成功全量校准封版**（orderSealed）且
    /// **纯追加**（所有新条目 seq 都大于本地现有最大 bridge seq）时才允许
    /// 跳过 renumber；任一不满足 → caller 直接 fallback 全量（= v1.14.22
    /// 已验证路径，不劣于现状）。
    ///
    /// - Parameters:
    ///   - orderSealed: 本会话已由成功全量校准写入定序封版标记
    ///   - deltaSeqs: 本次增量条目的 historySeq
    ///   - dbMaxBridgeSeq: 本地 DB 现有 bridge 行最大 seq（无基线 → nil）
    static func deltaFastPathAllowed(orderSealed: Bool, deltaSeqs: [Int], dbMaxBridgeSeq: Int?) -> Bool {
        guard orderSealed else { return false }
        guard let dbMaxBridgeSeq else { return false }
        guard !deltaSeqs.isEmpty else { return false }
        for seq in deltaSeqs where seq <= dbMaxBridgeSeq {
            return false
        }
        return true
    }

    // MARK: - delta 插入位置（[Fix v1.14.30] 对抗审查 S4）

    /// delta 增量行的插入计划：锚点 sort_order + 需要整体后移的行（从后往前）。
    ///
    /// 为什么不能盲追加 `max + 1`：DB 里可能已有"bridge history 尚未承载的
    /// live 行"（用户刚发的 U2，此时**上一轮**的回复才到达 delta）——盲追加会
    /// 把 U1 的回复排到 U2 **之后**，顺序错到下一次全量校准才修（S4 审查）。
    ///
    /// 锚点规则：
    /// 1. 本批 delta **认领到的最后一个 live 行**（unified 序里出现、DB 已
    ///    存在、且不是本批插入行）→ delta 内容在它之后（它是载体，不是新内容）；
    /// 2. 没有认领行（delta 内容全部位于 trailing live 行之前）→ 最后一个
    ///    回放行的位置。
    /// 锚点之后的行整体后移 `inserts.count` 位，插入行占住腾出的窗口。
    ///
    /// - Returns: `anchorOrder`（插入行从 anchorOrder + 1 起）与 `rowsToShift`
    ///   （已按 sort_order 降序，调用方依序 +count 即可）
    ///
    /// ⚠️ [Fix v1.14.30] 前置条件：`deltaInsertIsSafe == true`（纯尾段
    /// 插入）。夹心批次单一锚点必然错序——调用方必须先闸形态（见
    /// `deltaInsertIsSafe`；ChatStore 侧有后备闸拒绝执行）。
    static func deltaInsertPlan(
        unifiedFinalOrderIds: [String],
        inserts: [RawMessage],
        dbRows: [RawMessage]
    ) -> (anchorOrder: Int, rowsToShift: [RawMessage]) {
        let insertedIdSet = Set(inserts.map { $0.id })
        let rowById = Dictionary(uniqueKeysWithValues: dbRows.map { ($0.id, $0) })
        let anchorOrder: Int
        if let claimedId = unifiedFinalOrderIds.last(where: { !insertedIdSet.contains($0) }),
           let claimedRow = rowById[claimedId] {
            anchorOrder = claimedRow.sortOrder
        } else {
            anchorOrder = dbRows
                .filter { ReplayRowId.isReplayRow($0.id) }
                .map { $0.sortOrder }
                .max() ?? -1
        }
        let rowsToShift = dbRows
            .filter { $0.sortOrder > anchorOrder }
            .sorted { $0.sortOrder > $1.sortOrder }
        return (anchorOrder, rowsToShift)
    }

    /// [Fix v1.14.30 / 对抗审查 2·前提 2] delta 快路径的**形态安全性**：
    /// 插入行必须全部位于 unified 序的**纯尾段**（最后一个非插入行之后）。
    /// 「夹心」形态——插入行 → 认领行 →（插入行）——单一锚点规则只能把整批
    /// 插到最后认领行之后，夹在前段的插入行必然错序：
    ///   · 一批 delta 跨多个本地回合（快速连发两轮、中间无校准窗口），
    ///     U1 的回复被排到 U3 的输入之后；
    ///   · cursor 停在上轮回复中段（上次校准回滚），窗口同时含回复尾段
    ///     与新 user_input。
    /// - Returns: false = 混合批次，调用方必须放弃快路径（fallback 全量校准）。
    static func deltaInsertIsSafe(unifiedFinalOrderIds: [String], inserts: [RawMessage]) -> Bool {
        let insertedIdSet = Set(inserts.map { $0.id })
        guard let lastKeptIndex = unifiedFinalOrderIds.lastIndex(where: { !insertedIdSet.contains($0) }) else {
            return true  // 全是插入行（无认领行）→ 锚点 = 最后回放行，无夹心
        }
        guard let firstInsertIndex = unifiedFinalOrderIds.firstIndex(where: { insertedIdSet.contains($0) }) else {
            return true  // 没有插入行
        }
        return firstInsertIndex > lastKeptIndex
    }

    // MARK: - 段级定序（[Fix v1.14.30]）

    /// 回放区排序：past 行最先（按 index），随后按 (段首见次序, seq)。
    /// 段缺失/未登记时用现有相对顺序兜底（稳定排序由原始下标保证）。
    private static func sortedReplayRows(_ rows: [RawMessage], segmentRanks: [String: Int]) -> [RawMessage] {
        guard rows.count > 1 else { return rows }
        return rows.enumerated()
            .sorted { lhs, rhs in
                replaySortKey(lhs.element, rank: rank(of: lhs.element, segmentRanks: segmentRanks), index: lhs.offset)
                    < replaySortKey(rhs.element, rank: rank(of: rhs.element, segmentRanks: segmentRanks), index: rhs.offset)
            }
            .map { $0.element }
    }

    /// past 行 → -1（磁盘历史最早）；bridge 行 → 段 rank（未登记 → Int.max，
    /// 即排在已登记段之后、但仍保持彼此现有顺序）。
    private static func rank(of row: RawMessage, segmentRanks: [String: Int]) -> Int {
        if row.id.hasPrefix("past-") { return -1 }
        guard let segment = ReplayRowId.parseSegment(row.id) else { return Int.max }
        return segmentRanks[segment] ?? Int.max
    }

    private static func replaySortKey(_ row: RawMessage, rank: Int, index: Int) -> (Int, Int, Int) {
        // [Fix v1.14.30 / 对抗审查 S3] 段未登记（rank == Int.max：老形态无段 /
        // rank 表丢失）→ **不参与 seq 排序**，用原始下标兜底保持现有相对顺序
        // ——这是本函数文档写明的契约。旧实现仍按 seq 比较，直接违反注释：
        // 两个未登记段的行会被 seq 交叉重排（`[cccc-2, dddd-1]` 变
        // `[dddd-1, cccc-2]`），且与 past 特判叠加后跟既有测试互相矛盾
        // （CI 门里两条期望必红其一）。
        if rank == Int.max { return (Int.max, index, index) }
        let seq = ReplayRowId.parseBridgeSeq(row.id) ?? ReplayRowId.parsePastIndex(row.id) ?? Int.max
        return (rank, seq, index)
    }

    // MARK: - 内容匹配（已迁出）

    // [Fix v1.14.30] 用户正文归一化/配对（附件 XML 剥离、同文本 occurrence
    // 队列）已迁到独立模块 `RemoteHistoryOwnerIndex`（见
    // RemoteHistoryIdentity.swift）——"身份对账"与"定序"是两个改变的理由，
    // 不再混在本文件里。本文件只保留定序（planReplace / orderedRowSequence /
    // deltaFastPathAllowed / isTurnInProgress）。
}
