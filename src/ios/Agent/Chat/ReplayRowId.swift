// ReplayRowId — 远端回放行的持久化 id 命名空间。
//
// 背景（2026-09-11 v1.14.29，pp 真机 08:06 日志实证）：
// `messages.id` 是**全局** PRIMARY KEY（ChatStore `id TEXT PRIMARY KEY`），
// 但回放行 id 曾直接用 `bridge-{seq}` / `past-{index}`——seq 是
// **per-bridge-session** 计数、past index 是每次 fetch 的下标，两者都只在
// **单个会话内**唯一。两个本地会话各自同步过不同 bridge 会话时，同名 id
// 撞全局主键 → INSERT 直接失败：
//
//   [Store] replace INSERT failed mid=bridge-8 err=UNIQUE constraint failed: messages.id
//   [Store] replace INSERT failed mid=bridge-9 err=UNIQUE constraint failed: messages.id
//
// 后果：那一行内容永久落不了库（工具卡片/思考块/正文被吞），且每次校准
// 重试、每次失败（pp 真机：第一轮 Read 的思考 + 工具卡片丢失，
// orphanedOutputs=2）。
//
// 修法：id 前缀保持 `bridge-` / `past-`（既有全部前缀判定零改动），中间
// 插入**本地会话命名空间**（会话 UUID 前 8 位，十六进制无 `-`）：
//
//   bridge-{ns}-{seq}        past-{ns}-{index}
//
// 为什么命名空间用**本地会话 id** 而不是 bridgeId：bridge 会话切换
// （resume spawn 新会话）时，同一 seq 的 id 保持不变，旧行交由现成的
// seqSpaceReset 换血逻辑清理；若把 bridgeId 编进 id，旧行会因 id 不匹配
// 而残留成重复内容。
//
// 纯函数、无 DB/actor 依赖，单测在 RemoteHistoryBackfillTests。
//
// 关联：[[RemoteHistorySyncCore]] / [[RemoteHistoryBackfill]] / ChatStore.replaceRemoteHistory

import Foundation

enum ReplayRowId {

    /// 本地会话命名空间：会话 id 前 8 位。
    ///
    /// 会话 id 是 UUID（十六进制 + `-`），取前 8 位即纯十六进制，不含 `-`，
    /// 因此不会干扰 `parseBridgeSeq` 的按 `-` 切分取末段。
    static func namespace(sessionId: String) -> String {
        String(sessionId.prefix(8))
    }

    /// 回放行（bridge-{seq} / past-{index}，含命名空间形态）判别。
    /// 本地 agent 会话永不产生这两种前缀——`sessionNeedsRepair` 的
    /// 数据特征 gate 亦依赖该不变量。
    static func isReplayRow(_ id: String) -> Bool {
        id.hasPrefix("bridge-") || id.hasPrefix("past-")
    }

    /// bridge 回放行 id。namespace 为 nil 时退回旧形态（无命名空间）——
    /// 仅作为兜底，生产链路两处注入点都会带上 ns。
    static func bridge(seq: Int, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return "bridge-\(seq)" }
        return "bridge-\(namespace)-\(seq)"
    }

    /// 磁盘 past 回放行 id（同上）。
    static func past(index: Int, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return "past-\(index)" }
        return "past-\(namespace)-\(index)"
    }

    /// 从 `bridge-{seq}`（旧）或 `bridge-{ns}-{seq}`（新）解析 seq。
    static func parseBridgeSeq(_ id: String) -> Int? {
        guard id.hasPrefix("bridge-") else { return nil }
        guard let last = id.split(separator: "-").last else { return nil }
        return Int(last)
    }

    /// 从 `past-{index}` / `past-{ns}-{index}` 解析 index。
    static func parsePastIndex(_ id: String) -> Int? {
        guard id.hasPrefix("past-") else { return nil }
        guard let last = id.split(separator: "-").last else { return nil }
        return Int(last)
    }

    /// 一次性迁移：旧 id → 命名空间化 id。
    ///
    /// - 返回 nil = 无需迁移（已命名空间化 / 非回放行 / 解析失败）
    /// - 幂等：已迁移过的 id 再次传入返回 nil（目标 == 自身）
    static func migrationTarget(from id: String, namespace: String) -> String? {
        if let seq = parseBridgeSeq(id) {
            let target = bridge(seq: seq, namespace: namespace)
            return target == id ? nil : target
        }
        if let index = parsePastIndex(id) {
            let target = past(index: index, namespace: namespace)
            return target == id ? nil : target
        }
        return nil
    }
}
