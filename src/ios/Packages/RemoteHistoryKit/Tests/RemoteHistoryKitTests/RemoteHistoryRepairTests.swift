import XCTest
@testable import RemoteHistoryKit

/// `RemoteHistoryRepair` 的行为锁定（[Fix v1.14.33] · 模块 4/5）。
///
/// 稳态由 `RemoteTurnReconciler` 按 `remoteTurnKey` 精确吸收，但**已经写脏的
/// 库里没有 turnKey**。本模块是存量脏数据的自愈路径：判定依据是内容完全
/// 覆盖（同一已终结回合内逐个 part 对齐），不是位置、不是时间戳。
final class RemoteHistoryRepairTests: XCTestCase {

    private let server = RemoteHistoryFixture.serverRowsForSameTurn()

    // MARK: - part 身份键

    func test_partKey_text() {
        XCTAssertEqual(RemoteHistoryRepair.partKey(.text("abc")), "t:abc")
    }

    func test_partKey_toolUseByIdentity() {
        XCTAssertEqual(RemoteHistoryRepair.partKey(RemoteHistoryFixture.toolUse(id: "tu-9")), "u:tu-9")
    }

    func test_partKey_toolResultByIdentityNotOutput() {
        // 工具输出常被截断 → 只用 toolUseId，否则两侧永远对不上（假阴性）。
        XCTAssertEqual(
            RemoteHistoryRepair.partKey(RemoteHistoryFixture.toolResult(id: "tu-9", output: "x")),
            RemoteHistoryRepair.partKey(RemoteHistoryFixture.toolResult(id: "tu-9", output: "y")))
    }

    func test_partKey_mediaRefByRelativePath() {
        let ref = MediaRef(id: "m", relativePath: "a/b.png", mimeType: "image/png", originalFileName: nil)
        XCTAssertEqual(RemoteHistoryRepair.partKey(.mediaRef(ref)), "m:a/b.png")
    }

    // MARK: - 核心回归：真机 8-part 重复行

    func test_realDeviceAggregateRow_isDetectedAsRedundant() {
        let legacy = RemoteHistoryFixture.liveAggregateRow(turnKey: nil)
        let ids = RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [legacy], serverRaws: server, lastTurnFinished: true)
        XCTAssertEqual(ids, ["B274A31B"], "8 个 part 逐一对齐 → 判定为冗余副本")
    }

    // MARK: - 保守性（宁可不删）

    func test_partialCoverage_isNotRedundant() {
        let partial = RemoteHistoryFixture.row(
            id: "L1", role: .assistant,
            parts: [.text("t25"), RemoteHistoryFixture.toolUse(id: "tu-NOT-IN-SERVER")])
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [partial], serverRaws: server, lastTurnFinished: true).isEmpty,
            "有一个 part 服务端没有 = 本地是唯一副本")
    }

    func test_emptyParts_isNotRedundant() {
        // 空 parts 的多重集覆盖恒真 —— 必须显式排除，否则会误删"仅带本地错误"的行。
        let empty = RemoteHistoryFixture.row(id: "E1", role: .assistant, parts: [])
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [empty], serverRaws: server, lastTurnFinished: true).isEmpty)
    }

    func test_userRow_isNotRedundant() {
        let user = RemoteHistoryFixture.row(id: "U1", parts: [.text("看图")])
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [user], serverRaws: server, lastTurnFinished: true).isEmpty)
    }

    func test_rowWithLocalError_isNotRedundant() {
        let failed = RemoteHistoryFixture.row(
            id: "F1", role: .assistant, parts: [.text("t25")], errorInfo: "stream failed")
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [failed], serverRaws: server, lastTurnFinished: true).isEmpty)
    }

    func test_rowWithTurnKey_isLeftToSteadyStatePath() {
        // 有 turnKey 的行由 RemoteTurnReconciler 精确处理，本模块只管老数据。
        let modern = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1")
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [modern], serverRaws: server, lastTurnFinished: true).isEmpty)
    }

    func test_unfinishedTurn_isNotRedundant() {
        let legacy = RemoteHistoryFixture.liveAggregateRow(turnKey: nil)
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [legacy], serverRaws: server, lastTurnFinished: false).isEmpty,
            "进行中的回合内容不全，覆盖判定会假阳性")
    }

    func test_replayRows_areNeverTouched() {
        let replay = RemoteHistoryFixture.row(id: "bm-a1", role: .assistant, parts: [.text("t25")])
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [replay], serverRaws: server, lastTurnFinished: true).isEmpty)
    }

    func test_emptyServerSnapshot_returnsNothing() {
        let legacy = RemoteHistoryFixture.liveAggregateRow(turnKey: nil)
        XCTAssertTrue(RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [legacy], serverRaws: [], lastTurnFinished: true).isEmpty)
    }

    // MARK: - 幂等

    func test_isIdempotent_afterRemovalSecondRunIsEmpty() {
        let legacy = RemoteHistoryFixture.liveAggregateRow(turnKey: nil)
        let first = RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [legacy], serverRaws: server, lastTurnFinished: true)
        XCTAssertEqual(first, ["B274A31B"])
        let second = RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [], serverRaws: server, lastTurnFinished: true)
        XCTAssertTrue(second.isEmpty, "删完就不再命中 —— 不会来回抖")
    }

    // MARK: - 覆盖工具

    func test_isCovered_emptyNeededIsNeverCovered() {
        XCTAssertFalse(RemoteHistoryRepair.isCovered(needed: [:], by: ["t:a": 1]))
    }

    func test_isCovered_requiresEveryKey() {
        XCTAssertTrue(RemoteHistoryRepair.isCovered(needed: ["a": 1], by: ["a": 1, "b": 2]))
        XCTAssertFalse(RemoteHistoryRepair.isCovered(needed: ["a": 1, "c": 1], by: ["a": 1]))
        XCTAssertFalse(RemoteHistoryRepair.isCovered(needed: ["a": 2], by: ["a": 1]),
            "同文本出现两次必须服务端也有两个")
    }
}
