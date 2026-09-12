import XCTest
@testable import RemoteHistoryKit

/// `RemoteTurnModel` 的行为锁定（[Fix v1.14.33] 重复渲染根治 · 模块 1/5）。
///
/// 锁的是"同一条消息的两个化身（live 聚合行 / 服务端扁平行）属于同一回合"
/// 这套判定——重复渲染的病根就是缺少这一层，只能靠 uuid/正文逐行猜。
final class RemoteTurnModelTests: XCTestCase {

    // MARK: - 回合键

    func test_key_prefersClientMessageId() {
        XCTAssertEqual(RemoteTurnModel.key(clientMessageId: "cmid-1", fallbackAnchor: "bm-a1"), "cmid-1")
    }

    func test_key_fallsBackToAnchorWhenNoClientId() {
        XCTAssertEqual(RemoteTurnModel.key(clientMessageId: nil, fallbackAnchor: "bm-a1"), "turn@bm-a1")
    }

    func test_key_fallsBackOnEmptyClientId() {
        XCTAssertEqual(RemoteTurnModel.key(clientMessageId: "", fallbackAnchor: "bm-a1"), "turn@bm-a1")
    }

    // MARK: - 回合边界

    func test_boundary_trueForPlainUserRow() {
        let row = RemoteHistoryFixture.row(id: "u", parts: [.text("hi")])
        XCTAssertTrue(RemoteTurnModel.isUserInputBoundary(row))
    }

    func test_boundary_falseForToolResultOnlyUserRow() {
        // 回放的 tool_result 行 role 也是 user —— 当成边界会把一个工具回合
        // 切成 N 个回合（回合键退化 ⇒ 吸收判定失效 ⇒ 重复残留）。
        let row = RemoteHistoryFixture.row(id: "tr", parts: [RemoteHistoryFixture.toolResult(id: "tu-1")])
        XCTAssertTrue(row.isToolResultOnly)
        XCTAssertFalse(RemoteTurnModel.isUserInputBoundary(row))
    }

    func test_boundary_falseForAssistantRow() {
        let row = RemoteHistoryFixture.row(id: "a", role: .assistant, parts: [.text("hi")])
        XCTAssertFalse(RemoteTurnModel.isUserInputBoundary(row))
    }

    // MARK: - 切分

    func test_split_twoTurnsAtUserInputs() {
        let rows: [RawMessage] = [
            RemoteHistoryFixture.row(id: "u1", parts: [.text("a")], clientMessageId: "c1"),
            RemoteHistoryFixture.row(id: "a1", role: .assistant, parts: [.text("b")]),
            RemoteHistoryFixture.row(id: "u2", parts: [.text("c")], clientMessageId: "c2"),
            RemoteHistoryFixture.row(id: "a2", role: .assistant, parts: [.text("d")]),
        ]
        let turns = RemoteTurnModel.splitServerTurns(rows, lastTurnFinished: true)
        XCTAssertEqual(turns.map(\.key), ["c1", "c2"])
        XCTAssertEqual(turns[0].serverRowIds, ["u1", "a1"])
        XCTAssertEqual(turns[1].serverRowIds, ["u2", "a2"])
        XCTAssertTrue(turns[0].isFinished)
        XCTAssertTrue(turns[1].isFinished)
    }

    func test_split_toolResultsStayInSameTurn() {
        let rows: [RawMessage] = [
            RemoteHistoryFixture.row(id: "u1", parts: [.text("a")], clientMessageId: "c1"),
            RemoteHistoryFixture.row(id: "a1", role: .assistant, parts: [RemoteHistoryFixture.toolUse(id: "tu-1")]),
            RemoteHistoryFixture.row(id: "tr1", parts: [RemoteHistoryFixture.toolResult(id: "tu-1")]),
            RemoteHistoryFixture.row(id: "a2", role: .assistant, parts: [.text("done")]),
        ]
        let turns = RemoteTurnModel.splitServerTurns(rows, lastTurnFinished: true)
        XCTAssertEqual(turns.count, 1, "tool_result 不是回合边界")
        XCTAssertEqual(turns[0].serverRowIds, ["u1", "a1", "tr1", "a2"])
    }

    func test_split_headOrphanWhenWindowStartsMidTurn() {
        // trim 窗口从回合中间开始：这一截属于窗口外更早的回合，用哨兵键承载，
        // 不与任何 live 行的 turnKey 相等 ⇒ 不触发吸收（保守：宁可不删）。
        let rows: [RawMessage] = [
            RemoteHistoryFixture.row(id: "a1", role: .assistant, parts: [.text("x")]),
            RemoteHistoryFixture.row(id: "u1", parts: [.text("a")], clientMessageId: "c1"),
        ]
        let turns = RemoteTurnModel.splitServerTurns(rows, lastTurnFinished: true)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].key, RemoteTurnModel.headOrphanKey)
        XCTAssertEqual(turns[1].key, "c1")
    }

    func test_split_lastTurnFinishedPropagates() {
        let rows = RemoteHistoryFixture.serverRowsForSameTurn()
        let finished = RemoteTurnModel.splitServerTurns(rows, lastTurnFinished: true)
        XCTAssertTrue(finished[0].isFinished)
        let streaming = RemoteTurnModel.splitServerTurns(rows, lastTurnFinished: false)
        XCTAssertFalse(streaming[0].isFinished)
    }

    func test_split_emptyInput() {
        XCTAssertTrue(RemoteTurnModel.splitServerTurns([], lastTurnFinished: true).isEmpty)
    }

    // MARK: - 归属与吸收

    func test_turnIndex_byRemoteTurnKey() {
        let turns = RemoteTurnModel.splitServerTurns(
            RemoteHistoryFixture.serverRowsForSameTurn(), lastTurnFinished: true)
        let live = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1")
        XCTAssertEqual(RemoteTurnModel.turnIndex(forLiveRow: live, in: turns), 0)
    }

    func test_turnIndex_nilWhenNoTurnKey() {
        let turns = RemoteTurnModel.splitServerTurns(
            RemoteHistoryFixture.serverRowsForSameTurn(), lastTurnFinished: true)
        let legacy = RemoteHistoryFixture.liveAggregateRow(turnKey: nil)
        XCTAssertNil(RemoteTurnModel.turnIndex(forLiveRow: legacy, in: turns))
    }

    func test_shouldAbsorb_trueWhenTurnCarriedAndFinished() {
        let turns = RemoteTurnModel.splitServerTurns(
            RemoteHistoryFixture.serverRowsForSameTurn(), lastTurnFinished: true)
        XCTAssertTrue(RemoteTurnModel.shouldAbsorb(
            liveRow: RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1"), in: turns))
    }

    func test_shouldAbsorb_falseWhileTurnInProgress() {
        let turns = RemoteTurnModel.splitServerTurns(
            RemoteHistoryFixture.serverRowsForSameTurn(), lastTurnFinished: false)
        XCTAssertFalse(RemoteTurnModel.shouldAbsorb(
            liveRow: RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1"), in: turns),
            "进行中的回合：live 行是流式内容的唯一来源，删了内容就没了")
    }

    func test_shouldAbsorb_falseWhenServerHasNoRowsForTurn() {
        let turns = [RemoteTurn(key: "cmid-1", serverRowIds: [], isFinished: true)]
        XCTAssertFalse(RemoteTurnModel.shouldAbsorb(
            liveRow: RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1"), in: turns))
    }

    func test_shouldAbsorb_falseForUserRow() {
        let turns = RemoteTurnModel.splitServerTurns(
            RemoteHistoryFixture.serverRowsForSameTurn(), lastTurnFinished: true)
        let user = RemoteHistoryFixture.row(id: "UUID-U", parts: [.text("看图")], remoteTurnKey: "cmid-1")
        XCTAssertFalse(RemoteTurnModel.shouldAbsorb(liveRow: user, in: turns),
            "user 行携带附件/解析产物，信息量大于服务端副本")
    }

    func test_shouldAbsorb_falseWhenRowCarriesLocalError() {
        let turns = RemoteTurnModel.splitServerTurns(
            RemoteHistoryFixture.serverRowsForSameTurn(), lastTurnFinished: true)
        XCTAssertFalse(RemoteTurnModel.shouldAbsorb(
            liveRow: RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1", errorInfo: "boom"),
            in: turns), "带本地错误的行是这次失败的唯一记录")
    }

    func test_shouldAbsorb_falseForUnknownTurn() {
        let turns = RemoteTurnModel.splitServerTurns(
            RemoteHistoryFixture.serverRowsForSameTurn(), lastTurnFinished: true)
        XCTAssertFalse(RemoteTurnModel.shouldAbsorb(
            liveRow: RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-other"), in: turns))
    }
}
