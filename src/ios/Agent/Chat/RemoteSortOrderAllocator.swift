// RemoteSortOrderAllocator — 远端会话排序号的**唯一分配器**
// （[Fix v1.14.33] 乱序根治 · 模块 2/5）。
//
// 背景（乱序的直接成因）：此前排序号由两套互不相干的算术产生——
//   · live 落库：`nextSortOrder = MAX(sort_order)+1`（空库首行 0、次行 1）
//   · 服务端行：`stableSortOrders`（dbMax + 1000×k）+ `stableSegmentRenumber`
//     （段内整形；空间不足时 [D14] 整段上移到 `base = 1`）
// 第二套算术在"段外行序号 ≤ 1"时把 stable 段整体推到 1，与 live 行的
// `sort_order = 1` **撞号**（源码注释自承"允许与那个 ≤ 1 的烂段外行撞号"）。
// 撞号 ⇒ `ORDER BY sort_order` 结果未定义 ⇒ 两条消息每次重建都可能互换
// （乱序），且整形只改 stable 段、永不触碰那条 live 行 ⇒ 毒化**永久驻留**
// （pp 真机 2026-09-13：`ANOMALY dup=1 … head: 1,1,1001,…,11001`；杀进程
// 重启后一字不变）。
//
// 新契约（三条，全部可单测）：
//   1. **单一来源**：排序号只由"权威序中的位置"决定，`target = base + step × index`。
//   2. **稠密且严格递增**：永不产生重复值，永不产生 ≤ 1 的值（0/1 是 live 路径
//      的历史默认区，撞它就是撞车）。
//   3. **幂等**：同一权威序 + 同一现状 ⇒ 同一批目标号 ⇒ 现状已正确的行**不写**
//      （二次校准零写入）。追加新消息时只有新行及其后的行号变化。
//
// 为什么敢全会话稠密重排（旧实现刻意"只整 stable 段"）：旧实现的顾虑是
// "别碰非 stable 行"，但它靠稀疏锚点算术避免碰触，代价就是撞号与漂移。
// 稠密分配下**追加是稳定的**（尾部新增只影响新行），中间插空洞才需要重排
// ——那本来就是真实变化，理应写库。远端会话专用（gate 在上层），本地 agent
// 会话永不调用。
//
// 纯函数，单测在 RemoteSortOrderAllocatorTests。

import Foundation

enum RemoteSortOrderAllocator {

    /// 步长。固定值 = 幂等的必要条件（旧实现按当前跨度算 step，写完跨度变了
    /// → step 变了 → 前几行全变，每次同步都写库，即 B-4 非幂等缺陷）。
    static let defaultStep = 1000
    /// 起始序号。**必须 ≥ 2**：live 路径的 `MAX+1` 会产生 0 与 1，
    /// 从 1000 起即与该区间永久隔离（撞号在数值层面不可能发生）。
    static let defaultBase = 1000

    /// 按权威序分配排序号。
    ///
    /// - Parameters:
    ///   - orderedIds: 权威序（服务端序为主，live 占位行插在其回合之后）
    ///   - currentOrders: 现有行的排序号（DB 现状）
    ///   - step / base: 步长与起点（见常量注释）
    /// - Returns: **仅包含需要写入的行**（现状与目标不一致的行）；已正确的行不出现
    ///   ⇒ 幂等校准返回空字典。
    static func allocate(
        orderedIds: [String],
        currentOrders: [String: Int],
        step: Int = defaultStep,
        base: Int = defaultBase
    ) -> [String: Int] {
        let safeStep = max(step, 1)
        let safeBase = max(base, 2)
        var result: [String: Int] = [:]
        for (index, id) in orderedIds.enumerated() {
            let target = safeBase + safeStep * index
            if let current = currentOrders[id], current == target { continue }
            result[id] = target
        }
        return result
    }

    /// 权威序之外是否还有"漏网行"（防御性自检，供诊断/断言使用）。
    ///
    /// 权威序必须覆盖该会话全部行——漏一行就意味着它保持旧号，可能与新号
    /// 撞车（这正是 RC-3 的形态）。调用方应当在落库前断言本集合为空。
    static func missingRowIds(orderedIds: [String], allRowIds: [String]) -> [String] {
        let ordered = Set(orderedIds)
        return allRowIds.filter { !ordered.contains($0) }
    }

    /// 排序号体检：是否严格递增且无重复（幂等校准后应为 true）。
    static func isStrictlyIncreasing(_ orders: [Int]) -> Bool {
        guard orders.count > 1 else { return true }
        for index in 1..<orders.count where orders[index] <= orders[index - 1] {
            return false
        }
        return true
    }
}
