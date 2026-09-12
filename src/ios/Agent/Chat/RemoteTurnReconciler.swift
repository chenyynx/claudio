// RemoteTurnReconciler — 按**回合**对账服务端历史与本地行
// （[Fix v1.14.33] 重复渲染根治 · 模块 3/5）。
//
// 与 `planStableReplace` 的本质差异：
//
// | 维度 | planStableReplace（v1.14.31 起） | 本模块 |
// |---|---|---|
// | 合并依据 | 行 id 幂等 upsert | **回合**：live 聚合行 ↔ 该回合的服务端扁平行 |
// | live 聚合行 | 永不处理（永久保留 → 重复） | 回合被服务端承载且已终结 → **吸收删除** |
// | 回放 user 行 | 一律插入（与 live 行双份） | 命中本地承载行 → 不插（防双份） |
// | 未落库内容 | 一律排到会话末尾（甩尾） | 落在其**所属回合之后**（未知回合才排末尾） |
//
// 为什么不继续"补丁式修 planStableReplace"：assistant 回合的两份数据是
// 1:N 粒度关系（live 一行 8 parts ↔ 服务端 8 行各 1 part），**不存在任何
// 逐行 uuid/正文对账能判它们相等**——必须引入回合这一层（模块 1）。
//
// 保守性（宁可不删、不多删）：
//   · 吸收必须同时满足"有 turnKey + 回合已有服务端行 + 回合已终结 + 无本地错误"；
//   · 无 turnKey 的老 live 行**不在本模块吸收**，交由 `RemoteHistoryRepair`
//     的内容覆盖匹配（要求全部 part 逐个对齐，误判概率 ≈ 0）；
//   · user 行永不吸收（本地行携带附件/解析产物，其重复由插入侧 OwnerIndex 拦截）；
//   · 删除集**分级保护**：调用方传入的 `supersededLegacyIds` 里的 `bm-` 正主
//     一律不删（上游 id 空间可能搞混）；由 OwnerIndex 证实的 `redundantReplayIds`
//     可删（内容已被本地行承载，有据可依）。
//
// 纯函数（无 DB / actor / 网络），单测在 RemoteTurnReconcilerTests。

import Foundation

/// 回合对账计划。由 `ChatStore.applyTurnReconcile` 在单事务内执行。
struct RemoteTurnReconcilePlan {
    /// 需要插入的服务端行（按服务端序）
    let inserts: [RawMessage]
    /// 需要删除的行 id：被吸收的 live 聚合行 + 冗余回放行 + 旧形态副本
    let deleteIds: [String]
    /// **权威序**：该会话全部存活行的最终顺序，排序号由分配器据此生成
    let orderedIds: [String]
    /// 被吸收的 live 行（诊断）
    let absorbedLiveIds: [String]
    /// 本次是否为"无变化"（供上层跳过 UI 重建）
    var isEmpty: Bool { inserts.isEmpty && deleteIds.isEmpty }
}

enum RemoteTurnReconciler {

    static func plan(
        serverRaws: [RawMessage],
        dbRows: [RawMessage],
        lastTurnFinished: Bool,
        supersededLegacyIds: Set<String> = []
    ) -> RemoteTurnReconcilePlan {
        let dbRowById = Dictionary(
            dbRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dbIds = Set(dbRowById.keys)
        let turns = RemoteTurnModel.splitServerTurns(serverRaws, lastTurnFinished: lastTurnFinished)

        // 服务端行 id → 所属回合下标
        var turnIndexByServerId: [String: Int] = [:]
        for (index, turn) in turns.enumerated() {
            for id in turn.serverRowIds { turnIndexByServerId[id] = index }
        }

        // 1) 插入/占位决策：user 行走已验证的身份对账，非 user 行按 id 幂等。
        //
        // `placedLiveIds` 记录"已作为承载行占位"的本地行——步骤 2 必须跳过，
        // 否则同一行会在权威序里出现两次（占两个位 → 序号分配错位）。
        //
        // `seenClientMessageIds` 批次内去重：同 cmid 的第二条服务端 user 行
        // = 桥超录（watchdog 重发），不插入。OwnerIndex 只对 DB 行生效，
        // 当两条都是新行时 OwnerIndex 返回两条 `.unmatched` —— 必须在这里
        // 补一层批次级拦截。
        var owners = RemoteHistoryOwnerIndex(dbRows: dbRows, excluding: supersededLegacyIds)
        var inserts: [RawMessage] = []
        var placements: [(turnIndex: Int, rowId: String)] = []
        var placedLiveIds: Set<String> = []
        var redundantReplayIds: [String] = []
        var seenClientMessageIds: Set<String> = []

        for raw in serverRaws {
            let turnIndex = turnIndexByServerId[raw.id] ?? 0

            // 批次内超录拦截：同 cmid 的第二条 user 行直接跳过
            if let cmid = raw.clientMessageId, !cmid.isEmpty,
               !seenClientMessageIds.insert(cmid).inserted,
               raw.role == .user, !dbIds.contains(raw.id) {
                continue
            }

            let claim = owners.claimOwner(for: raw)

            if dbIds.contains(raw.id) {
                switch claim {
                case .owner(let owner) where owner != raw.id:
                    // 回放 user 行已在库 + 本地承载行也在库 = 同一条消息两份
                    // （v1.14.31 起的 stable 路径正是这么写脏的）。本地行信息
                    // 更全（附件/解析产物）→ 保留本地行、删除回放行，一次性收敛。
                    if placedLiveIds.insert(owner).inserted {
                        placements.append((turnIndex, owner))
                    }
                    redundantReplayIds.append(raw.id)
                default:
                    // 已在库且无本地承载行（含 .duplicate：已落库的行不再删，
                    // 删除风险高于保留——超录拦截的语义只针对"插入"）。
                    placements.append((turnIndex, raw.id))
                }
                continue
            }

            switch claim {
            case .owner(let owner):
                // 回放 user 行不插，本地承载行顶替它的位置（防双份气泡）
                if placedLiveIds.insert(owner).inserted {
                    placements.append((turnIndex, owner))
                }
            case .duplicate:
                // 桥超录副本（watchdog 重发）：既不插也不占位
                break
            case .unmatched:
                placements.append((turnIndex, raw.id))
                inserts.append(raw)
            }
        }

        // 2) live 行归属：吸收（冗余）或保留（其回合尚未被服务端承载）
        var absorbedLiveIds: [String] = []
        var survivorsByTurn: [Int: [RawMessage]] = [:]
        var unknownTurnRows: [RawMessage] = []
        for row in dbRows where !ReplayRowId.isReplayRow(row.id) {
            if supersededLegacyIds.contains(row.id) { continue }
            if placedLiveIds.contains(row.id) { continue }
            if RemoteTurnModel.shouldAbsorb(liveRow: row, in: turns) {
                absorbedLiveIds.append(row.id)
                continue
            }
            if let index = RemoteTurnModel.turnIndex(forLiveRow: row, in: turns) {
                survivorsByTurn[index, default: []].append(row)
            } else {
                unknownTurnRows.append(row)
            }
        }

        // 3) 删除集合（去重 + 分级保护）
        var seen = Set<String>()
        var deleteIds: [String] = []
        // 3a. 有据可依的两类：被吸收的 live 行、被本地行顶替的回放行
        for id in absorbedLiveIds + redundantReplayIds where seen.insert(id).inserted {
            deleteIds.append(id)
        }
        // 3b. 调用方判定的旧形态副本：`bm-` 正主一律不删（上游 id 空间误判防线）
        for id in supersededLegacyIds
        where ReplayRowId.parseStableUuid(id) == nil && seen.insert(id).inserted {
            deleteIds.append(id)
        }
        let deleteIdSet = Set(deleteIds)

        // 4) 权威序
        //
        // 4a. 头部：本次快照未覆盖的服务端行（窗口外的更早历史）+ 序号比所有
        //     回放行都小的"未知回合 live 行"（老数据无 turnKey，序号小 = 老内容）。
        //     二者按现有 sort_order 归并，保持历史相对位置。
        let serverIdSet = Set(serverRaws.map { $0.id })
        let replayFloor = dbRows
            .filter { ReplayRowId.isReplayRow($0.id) }
            .map(\.sortOrder)
            .max()
        let headRows = dbRows.filter { row in
            guard !deleteIdSet.contains(row.id) else { return false }
            if ReplayRowId.isReplayRow(row.id) { return !serverIdSet.contains(row.id) }
            guard unknownTurnRows.contains(where: { $0.id == row.id }) else { return false }
            guard let floor = replayFloor else { return false }
            return row.sortOrder <= floor
        }
        var orderedIds: [String] = headRows.sorted(by: Self.stableOrder).map { $0.id }

        // 4b. 主体：逐回合（服务端行按服务端序 + 本回合存活的 live 行）
        let headIdSet = Set(orderedIds)
        for (index, _) in turns.enumerated() {
            for placement in placements where placement.turnIndex == index {
                guard !deleteIdSet.contains(placement.rowId) else { continue }
                orderedIds.append(placement.rowId)
            }
            let survivors = (survivorsByTurn[index] ?? [])
                .filter { !headIdSet.contains($0.id) }
                .sorted(by: Self.stableOrder)
            for row in survivors where !deleteIdSet.contains(row.id) {
                orderedIds.append(row.id)
            }
        }

        // 4c. 尾部：序号在全部回放行之后的未知回合 live 行（= 服务端尚未承载的
        //     最新内容，语义与 v1.14.32 的 liveAfter 一致）
        let tailRows = unknownTurnRows
            .filter { !headIdSet.contains($0.id) }
            .filter { row in
                guard let floor = replayFloor else { return true }
                return row.sortOrder > floor
            }
            .sorted(by: Self.stableOrder)
        for row in tailRows where !deleteIdSet.contains(row.id) {
            orderedIds.append(row.id)
        }

        // 4d. 覆盖兜底：权威序必须覆盖该会话全部存活行——漏一行 = 它保持旧号，
        //     与新号撞车正是本次乱序的形态（RC-3）。正常应为空，非空时按现有
        //     序号补在末尾（宁可顺序次优，也不能留撞号）。
        let orderedIdSet = Set(orderedIds)
        let leftovers = dbRows
            .filter { !deleteIdSet.contains($0.id) && !orderedIdSet.contains($0.id) }
            .sorted(by: Self.stableOrder)
            .map { $0.id }
        orderedIds.append(contentsOf: leftovers)

        return RemoteTurnReconcilePlan(
            inserts: inserts,
            deleteIds: deleteIds,
            orderedIds: orderedIds,
            absorbedLiveIds: absorbedLiveIds
        )
    }

    /// 稳定排序：与 `loadMessages` 的 SQL `ORDER BY sort_order, created_at, id`
    /// 完全一致的三级 tiebreak。
    ///
    /// ⚠️ 为什么不能用 `sorted { $0.sortOrder < $1.sortOrder }`：Swift 的
    /// `sorted` **不保证稳定**，比较器返回 false 的等价元素（同 sort_order）
    /// 相对顺序未定义。脏库自愈的第一帧正是"若干行共享同一个 sort_order"
    /// （真机 `head: 1,1,1001,...`）——若排序不稳定，自愈当帧就把这些行的
    /// 相对顺序随机化一次，**本次要根治的症状在修复自己的过程中复现**。
    /// 三级 tiebreak 让"同号行"也有确定顺序，与 SQL 读取序对齐。
    private static func stableOrder(_ lhs: RawMessage, _ rhs: RawMessage) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }
}
