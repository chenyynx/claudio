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
// - user 行全保留（live 落库的用户消息，含附件 XML 解析结果等本地增强；
//   bridge 端 user_input 的图片等价信息少于本地行，换血反而丢数据）
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
    static func planReplace(historyRaws: [RawMessage], dbRows: [RawMessage]) -> RemoteHistoryReplacePlan {
        let dbIds = Set(dbRows.map { $0.id })

        // 删除：仅 live 落库的非 user UUID 行（id 非 "bridge-" 前缀）。
        // bridge-{seq} 行只增不删——bridge 端 trimHistory 只保留尾部 100 条，
        // 老的 seq 不在本次 history 集里，删了就是永久吞消息（R1 审查实锤）。
        let deleteIds = dbRows
            .filter { row in
                guard row.role != .user else { return false }
                return !row.id.hasPrefix("bridge-")
            }
            .map { $0.id }

        // 插入：history 中 DB 还没有的行（按 history 原序）。
        let inserts = historyRaws.filter { !dbIds.contains($0.id) }

        let keptCount = dbRows.count - deleteIds.count
        return RemoteHistoryReplacePlan(
            inserts: inserts,
            deleteIds: deleteIds,
            keptCount: keptCount
        )
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
