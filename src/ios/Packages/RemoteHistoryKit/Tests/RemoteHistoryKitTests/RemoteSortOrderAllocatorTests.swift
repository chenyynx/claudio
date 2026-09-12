import XCTest
@testable import RemoteHistoryKit

/// `RemoteSortOrderAllocator` 的行为锁定（[Fix v1.14.33] 乱序根治 · 模块 2/5）。
///
/// 乱序的直接成因是**两套互不相干的排序号算术**（live 的 `MAX+1` vs 服务端
/// 段的 `dbMax+1000k`/段内整形）。本模块用"唯一分配器"取代它们，锁的三条
/// 契约：稠密、严格递增、幂等。
final class RemoteSortOrderAllocatorTests: XCTestCase {

    func test_allocate_denseStrictlyIncreasing() {
        let orders = RemoteSortOrderAllocator.allocate(
            orderedIds: ["a", "b", "c", "d"], currentOrders: [:])
            .sorted { $0.value < $1.value }
            .map(\.value)
        XCTAssertEqual(orders, [1000, 2000, 3000, 4000])
    }

    func test_allocate_emptyInput() {
        XCTAssertTrue(RemoteSortOrderAllocator.allocate(orderedIds: [], currentOrders: [:]).isEmpty)
    }

    func test_allocate_idempotent_zeroWritesWhenAlreadyCorrect() {
        let current = ["a": 1000, "b": 2000, "c": 3000]
        let writes = RemoteSortOrderAllocator.allocate(
            orderedIds: ["a", "b", "c"], currentOrders: current)
        XCTAssertTrue(writes.isEmpty, "现状已正确的行绝不重写 —— 二次校准零写入")
    }

    func test_allocate_appendingRowLeavesPrefixUntouched() {
        let current = ["a": 1000, "b": 2000]
        let writes = RemoteSortOrderAllocator.allocate(
            orderedIds: ["a", "b", "c"], currentOrders: current)
        XCTAssertEqual(writes, ["c": 3000], "尾部追加只写新行")
    }

    func test_allocate_neverProducesValuesBelowTwo() {
        // live 路径的 `MAX+1` 会产生 0 与 1；从 ≥2 起即与该区间永久隔离。
        let writes = RemoteSortOrderAllocator.allocate(
            orderedIds: ["a", "b"], currentOrders: [:], step: 1, base: 0)
        XCTAssertEqual(writes["a"], 2)
        XCTAssertEqual(writes["b"], 3)
    }

    func test_allocate_stepClampedToAtLeastOne() {
        let writes = RemoteSortOrderAllocator.allocate(
            orderedIds: ["a", "b", "c"], currentOrders: [:], step: 0)
        XCTAssertEqual(writes["c"], 1002, "step=0 会退化成全部同号 —— 必须钳到 1")
    }

    func test_allocate_neverDuplicatesValuesRegardlessOfInputOrder() {
        let ids = (0..<50).map { "id-\($0)" }
        let writes = RemoteSortOrderAllocator.allocate(orderedIds: ids, currentOrders: [:])
        let values = ids.compactMap { writes[$0] }
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertTrue(RemoteSortOrderAllocator.isStrictlyIncreasing(values))
    }

    func test_allocate_rewritesRowWhoseOrderDrifted() {
        let writes = RemoteSortOrderAllocator.allocate(
            orderedIds: ["a", "b"], currentOrders: ["a": 1000, "b": 7777])
        XCTAssertEqual(writes, ["b": 2000])
    }

    // MARK: - 覆盖自检

    func test_missingRowIds_detectsLeftovers() {
        let missing = RemoteSortOrderAllocator.missingRowIds(
            orderedIds: ["a", "b"], allRowIds: ["a", "b", "c", "d"])
        XCTAssertEqual(Set(missing), ["c", "d"],
            "漏一行 = 它保持旧号 = 可能与新号撞车（RC-3 的形态）")
    }

    func test_missingRowIds_emptyWhenFullyCovered() {
        XCTAssertTrue(RemoteSortOrderAllocator.missingRowIds(
            orderedIds: ["a", "b"], allRowIds: ["b", "a"]).isEmpty)
    }

    // MARK: - 体检

    func test_isStrictlyIncreasing_true() {
        XCTAssertTrue(RemoteSortOrderAllocator.isStrictlyIncreasing([1, 2, 3]))
    }

    func test_isStrictlyIncreasing_falseOnDuplicate() {
        XCTAssertFalse(RemoteSortOrderAllocator.isStrictlyIncreasing([1, 1, 2]))
    }

    func test_isStrictlyIncreasing_falseOnRegression() {
        XCTAssertFalse(RemoteSortOrderAllocator.isStrictlyIncreasing([1, 3, 2]))
    }

    func test_isStrictlyIncreasing_trivialForZeroOrOne() {
        XCTAssertTrue(RemoteSortOrderAllocator.isStrictlyIncreasing([]))
        XCTAssertTrue(RemoteSortOrderAllocator.isStrictlyIncreasing([7]))
    }

    // MARK: - 回归：pp 真机 ANOMALY 形态（head: 1,1,1001,...,11001）

    func test_realDeviceAnomalyShape_isHealedBySingleAllocator() {
        // 真机脏数据：两条 sort_order = 1（live 行 + [D14] 段整形上移到 base=1）
        // 真机脏数据：两条 sort_order = 1（live 行 + [D14] 段整形上移到 base=1），
        // 其后 1001…11001。12 行 13 个号 ⇒ 必有重复 ⇒ ORDER BY 结果未定义。
        let dbRows = ["live", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11"]
        let dirtyOrders = [1, 1, 1001, 2001, 3001, 4001, 5001, 6001, 7001, 8001, 9001, 10001]
        XCTAssertEqual(Set(dirtyOrders).count, dirtyOrders.count - 1, "前置：脏数据确实撞号")

        let writes = RemoteSortOrderAllocator.allocate(
            orderedIds: dbRows,
            currentOrders: Dictionary(uniqueKeysWithValues: zip(dbRows, dirtyOrders)))
        let finalOrders = dbRows.map { writes[$0] ?? dirtyOrders[dbRows.firstIndex(of: $0)!] }
        XCTAssertEqual(Set(finalOrders).count, finalOrders.count,
            "单一分配器下撞号在数值层面不可能发生")
        XCTAssertTrue(RemoteSortOrderAllocator.isStrictlyIncreasing(finalOrders))
        XCTAssertEqual(finalOrders.min(), 1000)
    }
}
