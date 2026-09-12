// RemoteHistoryDiagnostics — 远端会话排序/重复的**统一体检与日志**
// （[Fix v1.14.33] · 模块 5/5）。
//
// 为什么单独成模块：此前"重复/乱序"的观测散落在三个地方、三种格式——
//   · ChatStore 的 `[ChatStore][ERROR][SortOrder] ANOMALY ...`
//   · RemoteHistoryBackfill 的 `[HistorySync] stable path done inserts=.. kept=..`
//   · delta 路径的 `delta hit but DB has no bridge baseline`
// 三处各说各话，出事后只能靠拼日志人肉推理（pp 真机 2026-09-13 那次正是
// 这么定位的——花了几天）。生产软件不能靠考古：体检必须是**一处定义、
// 结构化输出、可断言**。
//
// 本模块提供：
//   · `inspect(sessionId:rows:)` → 结构化体检报告（重复键、重复内容、覆盖遗漏）
//   · `log(...)` —— 统一的 `[SortOrder][ANOMALY]/[OK]/[REPAIR]` 日志行
//
// 纯函数 + 无副作用（日志用注入的闭包，便于单测断言），
// 单测在 RemoteHistoryDiagnosticsTests。

import Foundation

/// 一次会话的排序/重复体检结果。
struct RemoteHistoryHealthReport: Equatable {
    let sessionId: String
    /// 行数
    let count: Int
    /// 不同排序号的个数
    let uniqueOrders: Int
    /// 重复排序号的条数（> 0 = 渲染顺序未定义 = 乱序）
    let duplicateOrderCount: Int
    /// 排序号最小值 / 最大值
    let minOrder: Int
    let maxOrder: Int
    /// 未严格递增的位置数（按现有 sort_order 升序看，含相等与倒挂）
    let nonIncreasingCount: Int
    /// 内容完全相同的重复行组数（同 role + 同 part 身份键）
    let duplicateContentGroups: Int
    /// 前若干个排序号（日志 head，供人眼比对）
    let headOrders: [Int]

    /// 是否健康（可安全断言）
    var isHealthy: Bool {
        duplicateOrderCount == 0 && nonIncreasingCount == 0 && duplicateContentGroups == 0
    }
}

enum RemoteHistoryDiagnostics {

    /// 生成体检报告。`rows` 应为 DB 原样输出（按 sort_order 升序）。
    static func inspect(
        sessionId: String,
        rows: [RawMessage],
        headLimit: Int = 15
    ) -> RemoteHistoryHealthReport {
        let orders = rows.map { $0.sortOrder }
        let uniqueOrders = Set(orders).count
        var orderCounts: [Int: Int] = [:]
        for order in orders { orderCounts[order, default: 0] += 1 }
        let duplicateOrderCount = orderCounts.values.reduce(0) { $0 + max($1 - 1, 0) }

        var nonIncreasingCount = 0
        if orders.count > 1 {
            for index in 1..<orders.count where orders[index] <= orders[index - 1] {
                nonIncreasingCount += 1
            }
        }

        // 内容重复：同 role + 同 part 身份键序列（借用 Repair 的 partKey）
        var contentCounts: [String: Int] = [:]
        for row in rows {
            let key = row.role.rawValue + "|"
                + row.parts.map { RemoteHistoryRepair.partKey($0) }.joined(separator: ",")
            contentCounts[key, default: 0] += 1
        }
        let duplicateContentGroups = contentCounts.values.filter { $0 > 1 }.count

        return RemoteHistoryHealthReport(
            sessionId: sessionId,
            count: rows.count,
            uniqueOrders: uniqueOrders,
            duplicateOrderCount: duplicateOrderCount,
            minOrder: orders.min() ?? 0,
            maxOrder: orders.max() ?? 0,
            nonIncreasingCount: nonIncreasingCount,
            duplicateContentGroups: duplicateContentGroups,
            headOrders: Array(orders.prefix(headLimit))
        )
    }

    /// 统一日志行。`log` 注入便于单测断言（生产侧传 `{ Log.info(...)` 形式闭包）。
    static func log(
        _ report: RemoteHistoryHealthReport,
        stage: String,
        log: (String) -> Void
    ) {
        guard report.isHealthy else {
            log(
                "[SortOrder][ANOMALY] stage=\(stage) sid=\(report.sessionId.prefix(8)) "
                    + "count=\(report.count) uniq=\(report.uniqueOrders) dup=\(report.duplicateOrderCount) "
                    + "nonInc=\(report.nonIncreasingCount) dupContent=\(report.duplicateContentGroups) "
                    + "min=\(report.minOrder) max=\(report.maxOrder) "
                    + "head \(report.headOrders.count): \(report.headOrders.map(String.init).joined(separator: ","))"
            )
            return
        }
        log(
            "[SortOrder][OK] stage=\(stage) sid=\(report.sessionId.prefix(8)) "
                + "count=\(report.count) min=\(report.minOrder) max=\(report.maxOrder)"
        )
    }
}
