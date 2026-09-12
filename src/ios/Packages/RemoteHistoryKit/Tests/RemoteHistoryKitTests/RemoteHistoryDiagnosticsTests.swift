import XCTest
@testable import RemoteHistoryKit

/// `RemoteHistoryDiagnostics` 的行为锁定（[Fix v1.14.33] · 模块 5/5）。
///
/// 此前"重复/乱序"的观测散在三个地方三种格式，出事后只能拼日志人肉推理。
/// 本模块把体检收敛成一处定义、结构化输出、可断言。
final class RemoteHistoryDiagnosticsTests: XCTestCase {

    private func rows(_ orders: [Int]) -> [RawMessage] {
        orders.enumerated().map { index, order in
            RemoteHistoryFixture.row(
                id: "id-\(index)", role: .assistant,
                parts: [.text("body-\(index)")], sortOrder: order)
        }
    }

    func test_healthyReport() {
        let report = RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: rows([1000, 2000, 3000]))
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.count, 3)
        XCTAssertEqual(report.minOrder, 1000)
        XCTAssertEqual(report.maxOrder, 3000)
        XCTAssertEqual(report.duplicateOrderCount, 0)
    }

    func test_duplicateSortOrders_areCounted() {
        // 真机 ANOMALY 形态：两条 sort_order = 1
        let report = RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: rows([1, 1, 1001]))
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.duplicateOrderCount, 1)
        XCTAssertEqual(report.uniqueOrders, 2)
        XCTAssertEqual(report.nonIncreasingCount, 1)
    }

    func test_regression_isCounted() {
        let report = RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: rows([1000, 3000, 2000]))
        XCTAssertEqual(report.nonIncreasingCount, 1)
        XCTAssertEqual(report.duplicateOrderCount, 0, "倒挂不是撞号")
    }

    func test_duplicateContentGroups_areCounted() {
        let dup = [
            RemoteHistoryFixture.row(id: "a", role: .assistant, parts: [.text("same")], sortOrder: 1000),
            RemoteHistoryFixture.row(id: "b", role: .assistant, parts: [.text("same")], sortOrder: 2000),
            RemoteHistoryFixture.row(id: "c", role: .assistant, parts: [.text("other")], sortOrder: 3000),
        ]
        let report = RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: dup)
        XCTAssertEqual(report.duplicateContentGroups, 1)
        XCTAssertFalse(report.isHealthy)
    }

    func test_sameTextDifferentRole_isNotDuplicateContent() {
        let mixed = [
            RemoteHistoryFixture.row(id: "a", role: .user, parts: [.text("same")], sortOrder: 1000),
            RemoteHistoryFixture.row(id: "b", role: .assistant, parts: [.text("same")], sortOrder: 2000),
        ]
        XCTAssertEqual(RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: mixed).duplicateContentGroups, 0)
    }

    func test_headOrders_isTruncated() {
        let report = RemoteHistoryDiagnostics.inspect(
            sessionId: "S1", rows: rows(Array(stride(from: 1000, through: 5000, by: 1000))), headLimit: 3)
        XCTAssertEqual(report.headOrders, [1000, 2000, 3000])
    }

    func test_emptySession_isHealthy() {
        let report = RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: [])
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.minOrder, 0)
        XCTAssertEqual(report.maxOrder, 0)
    }

    // MARK: - 日志

    func test_log_emitsANOMALYWhenUnhealthy() {
        var lines: [String] = []
        RemoteHistoryDiagnostics.log(
            RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: rows([1, 1, 1001])),
            stage: "post-apply",
            log: { lines.append($0) })
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[SortOrder][ANOMALY]"))
        XCTAssertTrue(lines[0].contains("dup=1"))
        XCTAssertTrue(lines[0].contains("stage=post-apply"))
    }

    func test_log_emitsOKWhenHealthy() {
        var lines: [String] = []
        RemoteHistoryDiagnostics.log(
            RemoteHistoryDiagnostics.inspect(sessionId: "S1", rows: rows([1000, 2000])),
            stage: "post-apply",
            log: { lines.append($0) })
        XCTAssertTrue(lines[0].contains("[SortOrder][OK]"))
    }
}
