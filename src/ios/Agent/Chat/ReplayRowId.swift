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
// [stable history ids] 第三代形态 `bm-{messageUuid}`（桥侧 B1 起）
// ---------------------------------------------------------------
// 上两代的身份本质是**位置**（seq / index）——位置会随压缩、换桥会话、换磁盘
// transcript 而变，只能靠"段"消歧。桥侧 B1 给每条历史条目分配了**消息自己的**
// 稳定身份（CLI transcript UUID，压缩/重启/换会话恒定），于是位置身份可以
// 退役：`bm-{messageUuid}` 不再需要命名空间与段。
//
//   桥侧能力 `stable_history_ids` 开启 + 客户端 flag 开 → 落 bm- 形态；
//   否则（旧桥 / 关 flag / 回滚）→ 逐字保留上两代形态与全部逻辑。
//
// 降级链（仅为兜底，生产两处注入点都给全）：
//   bridge: bridge-{ns}-{seg}-{seq} → bridge-{ns}-{seq} → bridge-{seq}
//   past:   past-{ns}-{diskSeg}-{index} → past-{ns}-{index} → past-{index}
//   stable: bm-{messageUuid}（无降级——uuid 缺失即不启用本形态）
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

    /// 回放行（bridge-* / past-* / bm-*，含各代形态）判别。
    /// 本地 agent 会话永不产生这几种前缀——`sessionNeedsRepair` 的
    /// 数据特征 gate 亦依赖该不变量。
    ///
    /// ⚠️ `bm-` 必须在内：stable 路径落库的行用 `bm-{messageUuid}`，而**回滚**
    /// （关 flag / 降级桥）后旧路径仍会把这些行喂给 `planReplace`；旧路径按
    /// 「非 bridge-/past- 前缀 = live UUID 行」的规则会**误判为 live 行并删掉**
    /// （内容已由回放行承载的假设不成立）→ 历史被吞。此处放行 = 回滚安全的关键。
    static func isReplayRow(_ id: String) -> Bool {
        id.hasPrefix("bridge-") || id.hasPrefix("past-") || id.hasPrefix(stablePrefix)
    }

    // MARK: - [stable history ids] 第三代形态：稳定身份

    /// stable 回放行前缀。`bm-` = "bridge message"（bridge 分配的稳定身份）。
    static let stablePrefix = "bm-"

    /// stable 形态回放行 id：`bm-{messageUuid}`。
    ///
    /// 与 bridge-/past- 形态的本质区别：前两代的身份是**位置**（seq / index）
    /// ——压缩、换桥会话、换磁盘 transcript 后都会变，只能靠"段"消歧；本代
    /// 的身份是**消息自己**（CLI transcript UUID，桥侧 B1 注入），跨压缩/重启/
    /// 换会话恒定，因此不需要命名空间也不需要段。
    ///
    /// 仍加前缀的理由：① 与本地 live 行的 UUID 空间隔离，避免撞全局主键
    /// （`messages.id` 是全局 PRIMARY KEY）；② `isReplayRow` 可判别，旧路径
    /// 回滚时不误删。
    ///
    /// messageUuid 为空 → 返回 nil，调用方回退到 bridge-/past- 形态（旧桥零感知）。
    ///
    /// [防御] uuid 含 id 分隔符/空白/控制字符时返回 nil：`messages.id` 是全局
    /// 主键，若把 `-` 之外的可疑字符拼进来，① 会与 `bridge-`/`past-` 前缀判别
    /// 语义混淆；② 从 id 反解 uuid（`parseStableUuid`）会得到二次编码的脏值。
    /// 正常来源是 UUID（`[A-Fa-f0-9-]`）与桥的 CLI transcript uuid，均天然合法；
    /// 这里只是不让"上游传了脏值"变成静默的数据损坏。
    static func stable(messageUuid: String?) -> String? {
        guard let messageUuid, !messageUuid.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard messageUuid.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "\(stablePrefix)\(messageUuid)"
    }

    /// 从 stable 形态解析 messageUuid；非 stable 形态 → nil。
    static func parseStableUuid(_ id: String) -> String? {
        guard id.hasPrefix(stablePrefix) else { return nil }
        let uuid = String(id.dropFirst(stablePrefix.count))
        return uuid.isEmpty ? nil : uuid
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
