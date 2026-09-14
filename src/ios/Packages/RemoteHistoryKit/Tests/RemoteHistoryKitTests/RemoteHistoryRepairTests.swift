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

    // [S1a-批4 2026-09-14 语义改写] 原 test_rowWithTurnKey_isLeftToSteadyStatePath
    // 锁定「带 turnKey 的行 Repair 恒不参与」——该门本批移除（head-orphan 场景
    // Reconciler 吸收不到、Repair 又不收 = 两头不管，pp 真机 23:21 双行根因）。
    // 新语义下本形态（完整快照 + 正常可吸收）Repair **也会**命中；与 Reconciler
    // 吸收并集后经 mergedLegacy→deleteIds 去重仍只删一次，落库行为不变（等价性
    // 由本用例锁"命中"、Reconciler 侧 supersededLegacyIds 短路锁"不双删"）。
    func test_turnKeyRow_underFullSnapshot_alsoDetected() {
        let modern = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1")
        let ids = RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [modern], serverRaws: server, lastTurnFinished: true)
        XCTAssertEqual(ids, ["B274A31B"],
            "内容完全覆盖 + 强身份 + 已终结 → 参与判定（正常吸收行经合并去重，无副作用）")
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

// MARK: - [S1a-批4 2026-09-14] turnKey 门移除：head-orphan 自愈
final class RepairTurnKeyGateTests: XCTestCase {

    /// 掉窗形态：窗口从回合中间开始（边界 user 行被裁），服务端行 = 哨兵回合。
    /// live 聚合行带 turnKey="cmid-1" 与哨兵键不等 → Reconciler 吸收不到 →
    /// 旧门把它挡在 Repair 外 = 两头都不管（pp 真机 23:21 长回合双行根因之一）。
    func test_turnKeyLiveRow_headOrphanSelfHeals() {
        let live = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1")
        let orphanServer = Array(RemoteHistoryFixture.serverRowsForSameTurn().dropFirst())
        let ids = RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [live], serverRaws: orphanServer, lastTurnFinished: true)
        XCTAssertEqual(ids, ["B274A31B"], "内容被哨兵回合完全覆盖 + 强身份 → 可删")
    }

    func test_turnKeyLiveRow_inProgressTurn_survives() {
        let live = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1")
        let orphanServer = Array(RemoteHistoryFixture.serverRowsForSameTurn().dropFirst())
        let ids = RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [live], serverRaws: orphanServer, lastTurnFinished: false)
        XCTAssertTrue(ids.isEmpty, "回合未终结：live 行仍是内容唯一来源")
    }

    func test_turnKeyLiveRow_withErrorInfo_survives() {
        let live = RemoteHistoryFixture.liveAggregateRow(turnKey: "cmid-1", errorInfo: "boom")
        let orphanServer = Array(RemoteHistoryFixture.serverRowsForSameTurn().dropFirst())
        let ids = RemoteHistoryRepair.redundantLegacyLiveIds(
            dbRows: [live], serverRaws: orphanServer, lastTurnFinished: true)
        XCTAssertTrue(ids.isEmpty, "本地错误行是失败的唯一记录，硬否决不变")
    }
}
