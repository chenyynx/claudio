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
                // ⚠️ 覆盖集**必须剔除 user 输入行**（回合边界）。
                //
                // 不剔除的话：用户说「继续」、助手也回「继续」时，live 聚合行
                // 的 `t:继续` 会被 user 输入行自己的文本覆盖 → 判定"内容已被
                // 服务端承载" → 助手的 live 行被删。用户与助手的文本相同是
                // 极常见的对话形态（"好"/"继续"/"ok"/复述），误删率不低。
                // 助手内容的承载证明只能来自**非边界**的服务端行。
                guard !RemoteTurnModel.isUserInputBoundary(raw) else { continue }
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
            // ⚠️ 跨回合误匹配防线：本模块按"内容完全覆盖"判定，不依赖位置，
            // 所以同一条 live 行可能被**不是它所属回合**的服务端内容覆盖命中
            // （例：live 行是 turn5 的「继续」，服务端尚未回放 turn5，而 turn1
            // 恰好也有「继续」→ 误删 = turn5 内容永久丢失）。
            //
            // 化解：要求 live 行带**强身份** part（toolUse/toolResult，id 是
            // UUID，跨回合重复概率为 0），或 parts ≥ 2。单行纯文本的老重复
            // 因此保守保留（不自愈）——它们不造成工具回合那种成片重复，且
            // 稳态路径（有 turnKey 的新行）会精确处理后续所有重复。
            guard hasStrongIdentity(row.parts) else { continue }

            var needed: [String: Int] = [:]
            for part in row.parts { needed[partKey(part), default: 0] += 1 }

            for counts in coverageByTurn where isCovered(needed: needed, by: counts) {
                result.append(row.id)
                break
            }
        }
        return result
    }

    /// 是否含"强身份" part：**工具身份**（toolUseId 是 UUID，跨回合重复概率
    /// 为 0）或多 part（多个文本同时对齐的偶然性极低）。
    ///
    /// 纯单行文本的 live 行返回 false → 保守保留，不自愈。见
    /// `redundantLegacyLiveIds` 里的跨回合误匹配说明。
    static func hasStrongIdentity(_ parts: [ContentPart]) -> Bool {
        guard !parts.isEmpty else { return false }
        if parts.count >= 2 { return true }
        for part in parts {
            switch part {
            case .toolUse, .toolResult: return true
            case .text, .mediaRef: continue
            }
        }
        return false
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
