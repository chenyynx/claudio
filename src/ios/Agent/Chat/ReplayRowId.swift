// ReplayRowId — 远端回放行的持久化 id 形态（本地会话命名空间 + 两个"段"）。
//
// 为什么回放 id 必须自带身份（三轮真机事故的总结）：
// `messages.id` 是**全局** PRIMARY KEY，而回放行的天然身份全是**局部**的：
//   · bridge 行的 seq 是 per-bridge-session 计数（resume/重启从 1 重数）
//   · past 行的 index 是"某份磁盘 jsonl 的第几条"
// 直接用裸 id 会撞主键：v1.14.28 前 `bridge-{seq}` 跨会话撞 → INSERT 失败 →
// 工具卡片/思考/正文永久丢（pp 真机 2026-09-11 08:06：bridge-8/9/1
// UNIQUE constraint failed）。只加本地会话命名空间仍不够：同一 chat 被 iCloud
// 同步到两台设备时，各设备持**不同** bridge 会话 / **不同** claude 磁盘
// transcript，seq 与 index 都从 0/1 起 → 同 id 不同内容 → iCloud LWW 互相
// 覆盖（串台）+ keep 规则把错内容永久固化。
//
// 所以最终形态把两个"段"都编进去：
//
//   bridge-{ns}-{bridgeSeg}-{seq}      ns = 本地会话前 8 位
//   past-{ns}-{diskSeg}-{index}        bridgeSeg = bridge 会话前 8 位
//                                      diskSeg   = claude 会话（磁盘 transcript）前 8 位
//
// 于是「同一条回放行」的身份 = (本地会话, 内容来源, 序号)，与真实语义一一对应；
// 跨设备、跨 bridge 会话、跨 claude 会话都不再撞键。
//
// 降级链（仅为兜底，生产两处注入点都给全）：
//   bridge: bridge-{ns}-{seg}-{seq} → bridge-{ns}-{seq} → bridge-{seq}
//   past:   past-{ns}-{diskSeg}-{index} → past-{ns}-{index} → past-{index}
//
// 纯函数、无 DB/actor 依赖，单测在 ReplayRowIdTests。
//
// 关联：[[RemoteHistorySyncCore]] / [[RemoteHistoryIdentity]] / [[RemoteHistoryBackfill]] / ChatStore.replaceRemoteHistory

import Foundation

enum ReplayRowId {

    /// 本地会话命名空间：会话 id 前 8 位。
    ///
    /// 会话 id 是 UUID（十六进制 + `-`），取前 8 位即纯十六进制，不含 `-`，
    /// 因此不会干扰按 `-` 切分的解析。
    static func namespace(sessionId: String) -> String {
        String(sessionId.prefix(8))
    }

    /// 段：bridge 会话 id / claude 会话 id 前 8 位（线上格式均为 8 位十六进制，
    /// 见 bridge `session_created`、`lastHistoryBridgeId`、映射里的 claudeId）。
    /// 参数名故意中性（`id:`）——call site 分别传 bridgeId（bridge 段）与
    /// claudeId（disk 段），二者语义不同但都取前 8 位。
    static func segment(id: String) -> String {
        String(id.prefix(8))
    }

    /// 回放行（bridge-* / past-*，含各代形态）判别。
    /// 本地 agent 会话永不产生这两种前缀——`sessionNeedsRepair` 的
    /// 数据特征 gate 亦依赖该不变量。
    static func isReplayRow(_ id: String) -> Bool {
        id.hasPrefix("bridge-") || id.hasPrefix("past-")
    }

    // MARK: - 构造

    /// bridge 回放行 id。逐级降级见文件头。
    static func bridge(seq: Int, namespace: String?, segment: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return "bridge-\(seq)" }
        guard let segment, !segment.isEmpty else { return "bridge-\(namespace)-\(seq)" }
        return "bridge-\(namespace)-\(segment)-\(seq)"
    }

    /// past（磁盘 transcript）回放行 id。逐级降级见文件头。
    static func past(index: Int, namespace: String?, diskSegment: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return "past-\(index)" }
        guard let diskSegment, !diskSegment.isEmpty else { return "past-\(namespace)-\(index)" }
        return "past-\(namespace)-\(diskSegment)-\(index)"
    }

    // MARK: - 解析

    /// 从任一形态解析 bridge seq（末段数字）。
    static func parseBridgeSeq(_ id: String) -> Int? {
        guard id.hasPrefix("bridge-") else { return nil }
        guard let last = id.split(separator: "-").last else { return nil }
        return Int(last)
    }

    /// 从 `bridge-{ns}-{seg}-{seq}` 解析 bridge 段；更早形态（无段）→ nil。
    static func parseSegment(_ id: String) -> String? {
        guard id.hasPrefix("bridge-") else { return nil }
        let parts = id.split(separator: "-")
        guard parts.count >= 4 else { return nil }
        return String(parts[parts.count - 2])
    }

    /// 从 `past-{ns}-{diskSeg}-{index}` 解析磁盘段；更早形态（无段）→ nil。
    static func parseDiskSegment(_ id: String) -> String? {
        guard id.hasPrefix("past-") else { return nil }
        let parts = id.split(separator: "-")
        guard parts.count >= 4 else { return nil }
        return String(parts[parts.count - 2])
    }

    /// 从 `bridge-{ns}-…-{seq}` 解析本地会话命名空间。
    static func parseNamespace(_ id: String) -> String? {
        guard id.hasPrefix("bridge-") else { return nil }
        let parts = id.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        return String(parts[1])
    }

    /// 从任一形态解析 past index（末段数字）。
    static func parsePastIndex(_ id: String) -> Int? {
        guard id.hasPrefix("past-") else { return nil }
        guard let last = id.split(separator: "-").last else { return nil }
        return Int(last)
    }

    // MARK: - 一次性迁移（两代旧形态 → 目标形态）

    /// 计算迁移目标 id；nil = 不改写。
    ///
    /// 幂等与安全规则（对抗审查 2026-09-11 加固）：
    /// 1. **已带段的行一律不动**——`bridge-{ns}-{别的段}-{seq}` 可能是别的
    ///    设备/更早会话的行，改写成"当前段"会让它的内容顶替当前 seq
    ///    （串台），甚至因目标 id 已存在而被静默删除。
    /// 2. **外来命名空间不动**——`bridge-{别的ns}-{seq}` 不是本会话的行。
    /// 3. 段未知（调用方给不出）→ bridge 行不改写（past 行同理）。
    static func migrationTarget(
        from id: String,
        namespace: String,
        segment: String?,
        diskSegment: String?
    ) -> String? {
        if let seq = parseBridgeSeq(id) {
            if parseSegment(id) != nil { return nil }
            if let existingNs = parseNamespace(id), existingNs != namespace { return nil }
            guard let segment, !segment.isEmpty else { return nil }
            let target = bridge(seq: seq, namespace: namespace, segment: segment)
            return target == id ? nil : target
        }
        if let index = parsePastIndex(id) {
            if parseDiskSegment(id) != nil { return nil }
            guard let diskSegment, !diskSegment.isEmpty else { return nil }
            let target = past(index: index, namespace: namespace, diskSegment: diskSegment)
            return target == id ? nil : target
        }
        return nil
    }
}
