// RemoteSyncSegmentRegistry — bridge 段"首次见到"登记表（per 本地会话）。
//
// [Fix v1.14.30] 为什么需要它：回放行 id 里的 bridge 段（`bridge-{ns}-{seg}-{seq}`）
// 唯一标识了一个 seq 空间，但**段的先后关系无法从 id 推出**——段是随机 8 位
// 十六进制，字典序没有任何时间含义。
//
// 而顺序确实需要知道段的新旧：
//   · 同一本地会话先后连过多个 bridge 会话（resume / bridge 重启换 seq 空间）
//   · 同一 chat 会话被 iCloud 同步到多台设备，各设备持**不同** bridge 会话
//
// 所以这里按"本地**首次见到**该段"的顺序登记一个单调递增序号，排序时用作
// 段级 key（先见到的段 = 更早的历史）。同段内再按 seq 排。
//
// 语义边界（重要）：
// - 这是**每台设备各自的**观察顺序，不跨设备同步（设备各排各的，都对）。
// - 只增不改：已登记的段永不改 rank（否则历史顺序会随同步抖动）。
// - 容量无风险：一个会话的段数 = 它的 bridge 会话数（个位数~几十）。
//
// 存储：UserDefaults 单 key（per session）原子读写，与 cursor / 封版标记同款。
// 纯函数语义（除默认 UserDefaults 注入外无副作用），单测在
// RemoteSyncSegmentRegistryTests。

import Foundation

enum RemoteSyncSegmentRegistry {

    private static func key(sessionId: String) -> String {
        "RemoteSyncSegmentRanks.v1.\(sessionId)"
    }

    /// 登记本次见到的段，返回完整 rank 表（含历史段）。
    ///
    /// 新段按 `已登记最大 rank + 1` 递增；已存在的段保持原 rank。
    /// 无新段时不写盘。
    ///
    /// ⚠️ **新段之间按调用方给的先后次序分配 rank，不排序**（[Fix v1.14.30]
    /// 对抗审查 M2）：段是随机十六进制，字典序没有时间含义——一次调用里出现
    /// 多个全新段时（iCloud 合并两台设备的行 / 换 bridge 会话且换血未跑），
    /// 按字典序分配有 50% 概率把旧历史排到新历史后面，且写错的 rank 永不
    /// 修正（只增不改）。调用方按"这些段的行在本地 DB 的先后"传入即可
    /// （DB 的 sort_order 是上一次校准的产物，天然是时间序）。
    static func ranks(
        sessionId: String,
        segmentsInFirstSeenOrder: [String],
        defaults: UserDefaults = .standard
    ) -> [String: Int] {
        var table = load(sessionId: sessionId, defaults: defaults)
        let sanitized = segmentsInFirstSeenOrder.filter { !$0.isEmpty }
        guard !sanitized.isEmpty else { return table }

        var nextRank = (table.values.max() ?? -1) + 1
        var changed = false
        for segment in sanitized where table[segment] == nil {
            table[segment] = nextRank
            nextRank += 1
            changed = true
        }
        if changed {
            save(table, sessionId: sessionId, defaults: defaults)
        }
        return table
    }

    /// 只读当前 rank 表（诊断/测试用）。
    static func currentRanks(sessionId: String, defaults: UserDefaults = .standard) -> [String: Int] {
        load(sessionId: sessionId, defaults: defaults)
    }

    // MARK: - 私有：读写

    private static func load(sessionId: String, defaults: UserDefaults) -> [String: Int] {
        guard let data = defaults.data(forKey: key(sessionId: sessionId)) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private static func save(_ table: [String: Int], sessionId: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: key(sessionId: sessionId))
    }
}

/// 定序落座水位（[Fix v1.14.30.1 / 对抗审查·F1]）。
///
/// 背景：`orderedRowSequence` 把"未被 history 承载的 live user 行"一律当
/// 新内容甩 after 桶（v1.14.27 规则）。但"已被上一次校准落座、随后 bridge
/// 历史不再承载（trim 窗口 / resume 分界）"的历史行同样满足该条件——pp 真机
/// 实锤：会话第一条「你好」重进后出现在最新一条（perMsg 末位）。
/// 判据：每条**成功**校准（全量/delta/截断）收尾把当前 max sort_order 写为
/// 水位；下一轮 live user 行 sort_order ≤ 水位 = 已落座 → 回放区（before 尾），
/// > 水位 = 本轮之后新发 → after（原语义保持）。首轮无水位时以当前 DB 现状
/// 引导（所有现存行皆已落座）。设备本地语义（UserDefaults，per-session）。
enum RemoteSyncSettledWatermark {

    private static func key(sessionId: String) -> String {
        "RemoteSyncSettledMax.v1.\(sessionId)"
    }

    /// 水位；从未成功落库过返回 nil（调用方 bootstrap）。
    static func current(sessionId: String, defaults: UserDefaults = .standard) -> Int? {
        let v = defaults.integer(forKey: key(sessionId: sessionId))
        return v == 0 ? nil : v
    }

    static func set(sessionId: String, to maxSortOrder: Int, defaults: UserDefaults = .standard) {
        defaults.set(max(maxSortOrder, 0), forKey: key(sessionId: sessionId))
    }
}

/// 已被编辑/删除取代的原始输入协议身份（[Fix v1.14.30.1 / 对抗审查·F3]）。
///
/// 语义：bridge 无"撤回已投递输入"协议（官方亦无消息编辑能力，claudio 扩展），
/// 编辑重发后原输入仍活在 bridge 历史里——回放必与重发行并排 = 同一消息双份
/// （pp 真机 perMsg [26]/[27]、[40]/[41] 实锤）。截断路径（edit/resend/
/// regenerate/deleteFromMessage）删除 DB 行时把**被删 user 行的
/// clientMessageId** 登记于此；校准侧双重消化：①historyRaws 转换跳过这些
/// cmid（不 keep 不插入）②planReplace 删除规则清掉此前已入库的对应回放行。
/// 本地 agent 行 client_message_id 恒 NULL（隔离不变量）→ 永不登记。
enum RemoteSyncSupersededInputs {

    private static func key(sessionId: String) -> String {
        "RemoteSyncSuperseded.v1.\(sessionId)"
    }

    static func register(sessionId: String, clientMessageIds cmids: [String], defaults: UserDefaults = .standard) {
        guard !cmids.isEmpty else { return }
        var cur = Array(all(sessionId: sessionId, defaults: defaults))
        let curSet = Set(cur)
        let added = cmids.filter { !curSet.contains($0) }
        guard !added.isEmpty else { return }
        cur.append(contentsOf: added)
        // 容量护栏：FIFO 截尾（编辑是低频动作，50 足够宽）
        if cur.count > 50 { cur = Array(cur.suffix(50)) }
        if let data = try? JSONEncoder().encode(cur) {
            defaults.set(data, forKey: key(sessionId: sessionId))
        }
    }

    static func all(sessionId: String, defaults: UserDefaults = .standard) -> Set<String> {
        guard let data = defaults.data(forKey: key(sessionId: sessionId)),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }
}
