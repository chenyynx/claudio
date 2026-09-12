import XCTest
@testable import RemoteHistoryKit

/// `RemoteTurnReconciler` 的行为锁定（[Fix v1.14.33] 重复渲染根治 · 模块 3/5）。
///
/// 每个用例都是一条真机事故形态或一条"宁可不删"的保守性边界。核心回归是
/// `test_realDevice_duplicateAssistantTurn_isAbsorbed`：pp 真机 2026-09-13
/// 00:06 的 live 聚合行 vs 8 条服务端行，修了几天都没修掉的那一条。
final class RemoteTurnReconcilerTests: XCTestCase {

    // MARK: - 核心回归：重复渲染

    func test_realDevice_duplicateAssistantTurn_isAbsorbed() {
        let liveUser = RemoteHistoryFixture.row(
            id: "UUID-U1", parts: [.text("看图")],
            clientMessageId: "cmid-1", remoteTurnKey: "cmid-1", sortOrder: 1)
        let liveAssistant = RemoteHistoryFixture.liveAggregateRow(sortOrder: 2)
        let server = RemoteHistoryFixture.serverRowsForSameTurn()

        let plan = RemoteTurnReconciler.plan(
            serverRaws: server, dbRows: [liveUser, liveAssistant], lastTurnFinished: true)

        XCTAssertEqual(plan.inserts.map(\.id), ["bm-a1", "bm-a2", "bm-a3", "bm-a4", "bm-a5", "bm-a6", "bm-a7", "bm-a8"])
        XCTAssertEqual(plan.deleteIds, ["B274A31B"], "live 聚合行 = 冗余副本 → 吸收")
        XCTAssertEqual(plan.absorbedLiveIds, ["B274A31B"])
        // 最终 9 行：本地 user 行 + 8 条服务端行。没有第二份 assistant。
        XCTAssertEqual(plan.orderedIds, ["UUID-U1", "bm-a1", "bm-a2", "bm-a3", "bm-a4", "bm-a5", "bm-a6", "bm-a7", "bm-a8"])
    }

    func test_orderedIds_neverContainsTheSameRowTwice() {
        let liveUser = RemoteHistoryFixture.row(
            id: "UUID-U1", parts: [.text("看图")],
            clientMessageId: "cmid-1", remoteTurnKey: "cmid-1", sortOrder: 1)
        let plan = RemoteTurnReconciler.plan(
            serverRaws: RemoteHistoryFixture.serverRowsForSameTurn(),
            dbRows: [liveUser],
            lastTurnFinished: true)
        XCTAssertEqual(Set(plan.orderedIds).count, plan.orderedIds.count,
            "同一行占两个位 = 序号分配错位")
    }

    // MARK: - 流式未终结回合（不能吞内容）

    func test_streamingTurn_liveRowSurvivesAndIsPlacedAfterServerRows() {
        let liveUser = RemoteHistoryFixture.row(
            id: "UUID-U1", parts: [.text("看图")],
            clientMessageId: "cmid-1", remoteTurnKey: "cmid-1", sortOrder: 1)
        let liveAssistant = RemoteHistoryFixture.liveAggregateRow(sortOrder: 2)

        let plan = RemoteTurnReconciler.plan(
            serverRaws: RemoteHistoryFixture.serverRowsForSameTurn(),
            dbRows: [liveUser, liveAssistant],
            lastTurnFinished: false)

        XCTAssertTrue(plan.deleteIds.isEmpty, "回合进行中：live 行是流式内容的唯一来源")
        XCTAssertEqual(plan.orderedIds.last, "B274A31B")
    }

    // MARK: - 用户消息双份（插入侧拦截）

    func test_replayUserRow_matchingLocalRow_isNotInserted() {
        let liveUser = RemoteHistoryFixture.row(
            id: "UUID-U1", parts: [.text("你好")],
            clientMessageId: "cmid-1", remoteTurnKey: "cmid-1", sortOrder: 1)
        let server: [RawMessage] = [
            RemoteHistoryFixture.row(id: "bm-u1", parts: [.text("你好")], clientMessageId: "cmid-1"),
            RemoteHistoryFixture.row(id: "bm-a1", role: .assistant, parts: [.text("hi")]),
        ]
        let plan = RemoteTurnReconciler.plan(
            serverRaws: server, dbRows: [liveUser], lastTurnFinished: true)
        XCTAssertFalse(plan.inserts.contains { $0.id == "bm-u1" },
            "本地行已承载该用户消息 —— 回放行再插一次就是双气泡")
        XCTAssertEqual(plan.orderedIds, ["UUID-U1", "bm-a1"])
    }

    func test_persistedReplayUserRow_withLocalOwner_isDeletedOnceAndConverges() {
        // 升级路径的脏数据：bm- user 行与本地 user 行同时存在。
        let liveUser = RemoteHistoryFixture.row(
            id: "UUID-U1", parts: [.text("你好")],
            clientMessageId: "cmid-1", remoteTurnKey: "cmid-1", sortOrder: 1)
        let replayUser = RemoteHistoryFixture.row(
            id: "bm-u1", parts: [.text("你好")], clientMessageId: "cmid-1", sortOrder: 2)
        let server: [RawMessage] = [replayUser]

        let first = RemoteTurnReconciler.plan(
            serverRaws: server, dbRows: [liveUser, replayUser], lastTurnFinished: true)
        XCTAssertEqual(first.deleteIds, ["bm-u1"])
        XCTAssertTrue(first.inserts.isEmpty)

        // 收敛：删完再跑 = 空计划（不再有插入/删除）。
        let second = RemoteTurnReconciler.plan(
            serverRaws: server, dbRows: [liveUser], lastTurnFinished: true)
        XCTAssertTrue(second.isEmpty, "一次性收敛，不来回抖")
    }

    func test_bridgeOverRecordedDuplicate_isNotInserted() {
        // watchdog 重发：同一 cmid 两条回放行 → 第二条是超录副本。
        let server: [RawMessage] = [
            RemoteHistoryFixture.row(id: "bm-u1", parts: [.text("你好")], clientMessageId: "cmid-x"),
            RemoteHistoryFixture.row(id: "bm-u2", parts: [.text("你好")], clientMessageId: "cmid-x"),
        ]
        let plan = RemoteTurnReconciler.plan(serverRaws: server, dbRows: [], lastTurnFinished: true)
        XCTAssertEqual(plan.inserts.map(\.id), ["bm-u1"])
    }

    // MARK: - 保守性边界

    func test_stableRow_isNeverDeletedViaSupersededIds() {
        // 上游 id 空间可能搞混 —— bm- 正主必须从"被取代的旧副本"集合里剔除。
        let server = RemoteHistoryFixture.serverRowsForSameTurn()
        let plan = RemoteTurnReconciler.plan(
            serverRaws: server,
            dbRows: server,
            lastTurnFinished: true,
            supersededLegacyIds: ["bm-a1", "bridge-1-2-3"])
        XCTAssertFalse(plan.deleteIds.contains("bm-a1"))
        XCTAssertTrue(plan.deleteIds.contains("bridge-1-2-3"))
    }

    func test_legacyLiveRowWithoutTurnKey_isNotAbsorbedHere() {
        // 老数据（无 turnKey）交给 RemoteHistoryRepair 的内容覆盖匹配，
        // 本模块不猜 —— 否则一次误判就是永久丢内容。
        let legacy = RemoteHistoryFixture.liveAggregateRow(turnKey: nil, sortOrder: 5)
        let plan = RemoteTurnReconciler.plan(
            serverRaws: RemoteHistoryFixture.serverRowsForSameTurn(),
            dbRows: [legacy],
            lastTurnFinished: true)
        XCTAssertTrue(plan.deleteIds.isEmpty)
        XCTAssertTrue(plan.orderedIds.contains("B274A31B"))
    }

    func test_liveRowWithLocalError_isNeverAbsorbed() {
        let failed = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1", errorInfo: "stream failed")
        let plan = RemoteTurnReconciler.plan(
            serverRaws: RemoteHistoryFixture.serverRowsForSameTurn(),
            dbRows: [failed],
            lastTurnFinished: true)
        XCTAssertTrue(plan.deleteIds.isEmpty, "带本地错误的行是这次失败的唯一记录")
    }

    // MARK: - 顺序

    func test_rowsOutsideSnapshotWindow_comeFirst() {
        let outside1 = RemoteHistoryFixture.row(id: "bm-old1", parts: [.text("old1")], sortOrder: 1000)
        let outside2 = RemoteHistoryFixture.row(id: "bm-old2", parts: [.text("old2")], sortOrder: 2000)
        let liveUser = RemoteHistoryFixture.row(
            id: "UUID-U1", parts: [.text("new")],
            clientMessageId: "cmid-1", remoteTurnKey: "cmid-1", sortOrder: 3000)
        let liveAssistant = RemoteHistoryFixture.liveAggregateRow(sortOrder: 4000)
        let server = RemoteHistoryFixture.serverRowsForSameTurn()

        let plan = RemoteTurnReconciler.plan(
            serverRaws: server,
            dbRows: [outside1, outside2, liveUser, liveAssistant],
            lastTurnFinished: true)

        XCTAssertEqual(plan.orderedIds.prefix(2), ["bm-old1", "bm-old2"])
        // 2 外部 + 1 本地 user（顶替 bm-u1）+ 8 服务端 assistant 行 = 11
        XCTAssertEqual(plan.orderedIds.count, 11)
    }

    func test_unknownTurnLiveRows_splitByReplayFloor() {
        // 老数据无 turnKey：序号比所有回放行小 = 老内容（排前），否则 = 服务端
        // 尚未承载的最新内容（排尾，语义同 v1.14.32 的 liveAfter）。
        let replay = RemoteHistoryFixture.row(id: "bm-x", parts: [.text("x")], sortOrder: 1000)
        let oldLive = RemoteHistoryFixture.row(
            id: "legacy-old", role: .assistant, parts: [.text("old")], sortOrder: 500)
        let newLive = RemoteHistoryFixture.row(
            id: "legacy-new", role: .assistant, parts: [.text("new")], sortOrder: 5000)
        let server: [RawMessage] = [
            RemoteHistoryFixture.row(id: "bm-y", parts: [.text("y")], clientMessageId: "cmid-9"),
            RemoteHistoryFixture.row(id: "bm-z", role: .assistant, parts: [.text("z")]),
        ]
        let plan = RemoteTurnReconciler.plan(
            serverRaws: server, dbRows: [replay, oldLive, newLive], lastTurnFinished: true)
        XCTAssertEqual(plan.orderedIds, ["legacy-old", "bm-x", "bm-y", "bm-z", "legacy-new"])
    }

    func test_multiTurnOrder_followsServerSequence() {
        let server: [RawMessage] = [
            RemoteHistoryFixture.row(id: "bm-u1", parts: [.text("q1")], clientMessageId: "c1"),
            RemoteHistoryFixture.row(id: "bm-a1", role: .assistant, parts: [.text("a1")]),
            RemoteHistoryFixture.row(id: "bm-u2", parts: [.text("q2")], clientMessageId: "c2"),
            RemoteHistoryFixture.row(id: "bm-a2", role: .assistant, parts: [.text("a2")]),
        ]
        let plan = RemoteTurnReconciler.plan(serverRaws: server, dbRows: [], lastTurnFinished: true)
        XCTAssertEqual(plan.orderedIds, ["bm-u1", "bm-a1", "bm-u2", "bm-a2"])
    }

    func test_headOrphanRowsDoNotAbsorbAnything() {
        // 窗口从回合中间开始：哨兵回合不与任何 live 行 turnKey 相等。
        let live = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1", sortOrder: 1)
        let server: [RawMessage] = [
            RemoteHistoryFixture.row(id: "bm-a1", role: .assistant, parts: [.text("mid")]),
        ]
        let plan = RemoteTurnReconciler.plan(
            serverRaws: server, dbRows: [live], lastTurnFinished: true)
        XCTAssertTrue(plan.deleteIds.isEmpty)
    }

    // MARK: - 覆盖不变式

    func test_orderedIds_coverEverySurvivingRow() {
        let outside = RemoteHistoryFixture.row(id: "bm-old1", parts: [.text("old")], sortOrder: 1000)
        let liveUser = RemoteHistoryFixture.row(
            id: "UUID-U1", parts: [.text("new")],
            clientMessageId: "cmid-1", remoteTurnKey: "cmid-1", sortOrder: 3000)
        let liveAssistant = RemoteHistoryFixture.liveAggregateRow(sortOrder: 4000)
        let dbRows = [outside, liveUser, liveAssistant]
        let plan = RemoteTurnReconciler.plan(
            serverRaws: RemoteHistoryFixture.serverRowsForSameTurn(),
            dbRows: dbRows,
            lastTurnFinished: false)

        let survivors = Set(dbRows.map(\.id)).subtracting(plan.deleteIds)
        let missing = RemoteSortOrderAllocator.missingRowIds(
            orderedIds: plan.orderedIds, allRowIds: Array(survivors))
        XCTAssertTrue(missing.isEmpty, "漏一行 = 它保持旧号 = 撞车")
    }
}
