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
    static func planReplace(historyRaws: [RawMessage], dbRows: [RawMessage], nonEngineSeqs: Set<Int> = [], forceFullReshuffle: Bool = false, evictPastRows: Bool = false) -> RemoteHistoryReplacePlan {
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
        func bridgeSeq(_ id: String) -> Int? {
            guard id.hasPrefix("bridge-") else { return nil }
            return Int(id.split(separator: "-").last ?? "")
        }
        let dbBridgeSeqs = dbRows.compactMap { $0.role != .user ? bridgeSeq($0.id) : nil }
        let historySeqs = historyRaws.compactMap { bridgeSeq($0.id) }
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
                guard row.role != .user else { return false }
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
        // [排查 2026-09-10] user 行防双份（live UUID 行与回放 bridge-{seq}
        // 行并存 = 同一消息渲染两次 + UUID 行按旧 sort_order 进保留区错位）。
        // 换血方向选"保本地删回放"——本地行带 mediaRef/解析产物。两类键：
        // · toolResult-only user 行按 toolUseId 比对（同一工具调用稳定唯一）
        // · text user 行按首条 text 比对
        var liveToolResultIds = Set<String>()
        var liveUserTexts = Set<String>()
        // toolUseId/text → 本地承载行 id（防双份命中时 unifiedFinalOrderIds
        // 用本地行替换该 history 位置，user 行才不会在 renumber 时被甩到最前）
        var liveToolResultOwner: [String: String] = [:]
        var liveUserTextOwner: [String: String] = [:]
        for row in dbRows where row.role == .user && !deleteIdSet.contains(row.id) {
            switch row.parts.first {
            case .toolResult(let tr):
                if liveToolResultIds.insert(tr.toolUseId).inserted {
                    liveToolResultOwner[tr.toolUseId] = row.id
                }
            case .text(let t):
                if liveUserTexts.insert(t).inserted {
                    liveUserTextOwner[t] = row.id
                }
            default:
                break
            }
        }
        let keptIds = dbIds.subtracting(deleteIdSet)
        var inserts: [RawMessage] = []
        var unifiedFinalOrderIds: [String] = []
        for raw in historyRaws {
            var localOwnerId: String?
            if keptIds.contains(raw.id) {
                // 已在 DB（回放行命中 keep/不重插）——直接占位
                unifiedFinalOrderIds.append(raw.id)
                continue
            }
            if raw.role == .user {
                switch raw.parts.first {
                case .toolResult(let tr):
                    if let owner = liveToolResultOwner[tr.toolUseId] {
                        localOwnerId = owner
                    }
                case .text(let t):
                    if let owner = liveUserTextOwner[t] {
                        localOwnerId = owner
                    }
                default:
                    break
                }
            }
            if let owner = localOwnerId {
                // 防双份：回放 user 行不插，本地行顶替它在 bridge 序里的位置
                unifiedFinalOrderIds.append(owner)
                continue
            }
            unifiedFinalOrderIds.append(raw.id)
            inserts.append(raw)
        }

        let keptCount = dbRows.count - deleteIds.count
        return RemoteHistoryReplacePlan(
            inserts: inserts,
            deleteIds: deleteIds,
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
        rowById: [String: RawMessage]
    ) -> [RawMessage] {
        var before: [RawMessage] = []
        var after: [RawMessage] = []
        for row in retainedRows {
            // bridge-/past- 前缀 = 回放行（老历史，排前）；其余（live UUID）
            // = 本地新内容（排后）。
            if row.id.hasPrefix("bridge-") || row.id.hasPrefix("past-") {
                before.append(row)
            } else {
                after.append(row)
            }
        }
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
}
