// RemoteHistoryRepair — 远端会话**脏数据的一次性自愈**（[Fix v1.14.33] · 模块 4/5）。
//
// 为什么必须有这一层：稳态由 `RemoteTurnReconciler` 按 `remoteTurnKey` 精确
// 吸收，但**已经写脏的库里没有 turnKey**（该列与"回合键"概念都是本次新增）。
// 只修稳态 = 存量脏数据永久残留——pp 真机 2026-09-13：`ANOMALY dup=1 min=1
// max=11001`，杀进程重启后一字不变（没有任何自愈路径）。
//
// 本模块只做一件事：**判定"某条老 live 聚合行是否是服务端内容的冗余副本"**。
// 判定依据不是位置、不是时间戳，而是**内容完全覆盖**：
//
//   该行的每一个 part 都能在**同一个已终结回合**的服务端行里找到同类型同
//   身份的 part（多重集覆盖）。
//
// 为什么敢这么判：pp 真机日志里那条重复行是
//   live: [text=25c, text=77c, toolUse:Read×3, toolResult×3]
//   服务端: bm-a3114(text=25c) … bm-0a762(text=77c) 共 8 行逐 part 对应
// 8 个 part 逐个对齐且落在同一回合内，误判概率 ≈ 0。
//
// 幂等：判定只依赖 DB 现状与服务端快照，删完就不再命中（第二次跑返回空）。
//
// 纯函数（无 DB / actor / 网络），单测在 RemoteHistoryRepairTests。

import Foundation

enum RemoteHistoryRepair {

    /// part 的**身份键**：只取"能确定同一份内容"的字段，不取会被裁剪/改写的
    /// 字段（工具输出常被截断，故 toolResult 只用 toolUseId）。
    ///
    /// - .text → 正文原样（live 行与回放行同源，逐字相同）
    /// - .toolUse → toolUseId（同一次调用在两侧必然一致）
    /// - .toolResult → toolUseId（**不用 output**：截断策略不同会导致假阴性；
    ///   而一次 toolUseId 只会有一个结果，足以确定同一份内容）
    /// - .mediaRef → 媒体路径
    static func partKey(_ part: ContentPart) -> String {
        switch part {
        case .text(let s):
            return "t:\(s)"
        case .mediaRef(let ref):
            return "m:\(ref.relativePath)"
        case .toolUse(let tu):
            return "u:\(tu.toolUseId)"
        case .toolResult(let tr):
            return "r:\(tr.toolUseId)"
        }
    }

    /// 老 live 聚合行中"内容已被服务端完全覆盖"的冗余副本 id。
    ///
    /// 参与条件（全部满足才可能命中——宁可不删）：
    ///   1. 本地 live 行（非回放行）且**没有** `remoteTurnKey`（老数据）；
    ///   2. 非 user 行（user 行的去重视由 OwnerIndex 在插入侧负责）；
    ///   3. parts 非空（空 parts 的多重集覆盖恒真 —— 必须显式排除，否则会
    ///      把"仅携带本地错误的空行"误删）；
    ///   4. 无 `errorInfo`（同 `RemoteTurnModel.shouldAbsorb` 的硬否决）；
    ///   5. 存在某个**已终结**回合，其服务端行的 part 多重集**完全覆盖**本行。
    ///
    /// - Parameters:
    ///   - dbRows: 本地 DB 现有行
    ///   - serverRaws: 本次快照的服务端行（按服务端序）
    ///   - lastTurnFinished: 末回合是否已终结
    static func redundantLegacyLiveIds(
        dbRows: [RawMessage],
        serverRaws: [RawMessage],
        lastTurnFinished: Bool
    ) -> [String] {
        let turns = RemoteTurnModel.splitServerTurns(serverRaws, lastTurnFinished: lastTurnFinished)
        guard !turns.isEmpty else { return [] }

        // 逐回合的服务端 part 多重集（只算已终结回合：进行中的回合内容不全，
        // 覆盖判定会假阳性）。
        let serverIdByTurn = turns.map { Set($0.serverRowIds) }
        var coverageByTurn: [[String: Int]] = []
        for (index, turn) in turns.enumerated() {
            guard turn.isFinished else {
                coverageByTurn.append([:])
                continue
            }
            var counts: [String: Int] = [:]
            for raw in serverRaws where serverIdByTurn[index].contains(raw.id) {
                for part in raw.parts {
                    counts[partKey(part), default: 0] += 1
                }
            }
            coverageByTurn.append(counts)
        }

        var result: [String] = []
        for row in dbRows {
            guard !ReplayRowId.isReplayRow(row.id) else { continue }
            guard row.remoteTurnKey == nil || row.remoteTurnKey?.isEmpty == true else { continue }
            guard row.role != .user else { continue }
            guard !row.parts.isEmpty else { continue }
            guard row.errorInfo == nil else { continue }

            var needed: [String: Int] = [:]
            for part in row.parts { needed[partKey(part), default: 0] += 1 }

            for counts in coverageByTurn where isCovered(needed: needed, by: counts) {
                result.append(row.id)
                break
            }
        }
        return result
    }

    /// 多重集覆盖：`by` 中每个键的数量都 ≥ `needed`。空 `needed` 恒不覆盖
    /// （调用方已排除空 parts，这里是第二道防线）。
    static func isCovered(needed: [String: Int], by available: [String: Int]) -> Bool {
        guard !needed.isEmpty else { return false }
        for (key, count) in needed {
            guard (available[key] ?? 0) >= count else { return false }
        }
        return true
    }
}
