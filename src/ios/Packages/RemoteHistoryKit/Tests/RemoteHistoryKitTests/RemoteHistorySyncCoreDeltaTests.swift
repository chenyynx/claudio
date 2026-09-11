import XCTest
@testable import RemoteHistoryKit

/// RemoteHistorySyncCore 的两组纯函数锁定。
///
/// 1. `deltaFastPathAllowed`（[Fix v1.14.29]）—— 增量快路径闸门：delta 只含
///    增量条目，把残缺序喂给 renumber 会把用户全部发言甩到会话末尾
///    （pp 真机 2026-09-11 08:06 实证）。准入 = 定序已封版 + 纯追加。
/// 2. `orderedRowSequence` 的段级定序（[Fix v1.14.30]）—— 多段并存
///    （换过 bridge 会话 / 多设备共享同一 chat 会话）时按
///    (段首见次序, seq) 排；past 行恒最先；live UUID 行恒最后。
///
/// 注：用户文本归一化/配对（附件 XML、同文本 occurrence）已迁到
/// RemoteHistoryOwnerIndex，用例见 RemoteHistoryIdentityTests。
final class RemoteHistorySyncCoreDeltaTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRaw(id: String, role: MessageRole = .assistant, text: String = "t", sortOrder: Int = 0) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: [.text(text)],
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil
        )
    }

    // MARK: - deltaFastPathAllowed

    func test_deltaFastPath_deniedWhenNotSealed() {
        XCTAssertFalse(
            RemoteHistorySyncCore.deltaFastPathAllowed(orderSealed: false, deltaSeqs: [21, 22], dbMaxBridgeSeq: 20),
            "未封版的会话（新装/刚升级/旧版写坏过）必须回全量——这是旧数据自愈的唯一入口"
        )
    }

    func test_deltaFastPath_deniedWhenNotPureAppend() {
        XCTAssertFalse(
            RemoteHistorySyncCore.deltaFastPathAllowed(orderSealed: true, deltaSeqs: [18, 19], dbMaxBridgeSeq: 25),
            "增量 seq 落在 DB 已有 seq 之下（中间补洞）→ 追加语义不成立，必须回全量"
        )
        XCTAssertFalse(
            RemoteHistorySyncCore.deltaFastPathAllowed(orderSealed: true, deltaSeqs: [25, 26], dbMaxBridgeSeq: 25),
            "seq 等于现有最大同样不是纯追加"
        )
    }

    func test_deltaFastPath_deniedWithoutBaselineOrEntries() {
        XCTAssertFalse(
            RemoteHistorySyncCore.deltaFastPathAllowed(orderSealed: true, deltaSeqs: [1], dbMaxBridgeSeq: nil),
            "DB 无 bridge 基线 → 无从判断追加语义"
        )
        XCTAssertFalse(
            RemoteHistorySyncCore.deltaFastPathAllowed(orderSealed: true, deltaSeqs: [], dbMaxBridgeSeq: 20),
            "空 delta 不走快路径（caller 直返 no-op，连 planReplace 都不进）"
        )
    }

    func test_deltaFastPath_allowedWhenSealedAndPureAppend() {
        XCTAssertTrue(
            RemoteHistorySyncCore.deltaFastPathAllowed(orderSealed: true, deltaSeqs: [21, 22], dbMaxBridgeSeq: 20)
        )
    }

    // MARK: - orderedRowSequence 段级定序

    func test_orderedRowSequence_multiSegment_ordersBySegmentRank() {
        // 段 A 先见到（rank 0），段 B 后见到（rank 1）——即便传入顺序反了，
        // 也必须按段序排（段是随机十六进制，不排就是乱序）。
        let segB2 = makeRaw(id: "bridge-ns-bbbb-2")
        let segA1 = makeRaw(id: "bridge-ns-aaaa-1")
        let segB1 = makeRaw(id: "bridge-ns-bbbb-1")
        let segA2 = makeRaw(id: "bridge-ns-aaaa-2")
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: [],
            finalOrder: [],
            retainedRows: [segB2, segA1, segB1, segA2],
            rowById: [:],
            segmentRanks: ["aaaa": 0, "bbbb": 1]
        )
        XCTAssertEqual(sequence.map { $0.id },
                       ["bridge-ns-aaaa-1", "bridge-ns-aaaa-2", "bridge-ns-bbbb-1", "bridge-ns-bbbb-2"],
                       "段内按 seq、段间按首见次序")
    }

    func test_orderedRowSequence_pastRowsAlwaysFirst() {
        let past = makeRaw(id: "past-ns-0", role: .user)
        let bridge = makeRaw(id: "bridge-ns-aaaa-1")
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: [],
            finalOrder: [],
            retainedRows: [bridge, past],
            rowById: [:],
            segmentRanks: ["aaaa": 0]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["past-ns-0", "bridge-ns-aaaa-1"],
                       "past 行是磁盘历史，早于任何 bridge 会话")
    }

    func test_orderedRowSequence_unknownSegmentKeepsRelativeOrder() {
        // 段未登记（老 id / 无 rank 表）→ 退回传入顺序，不得打乱。
        let a = makeRaw(id: "bridge-ns-cccc-2")
        let b = makeRaw(id: "bridge-ns-dddd-1")
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: [],
            finalOrder: [],
            retainedRows: [a, b],
            rowById: [:],
            segmentRanks: [:]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["bridge-ns-cccc-2", "bridge-ns-dddd-1"])
    }

    func test_orderedRowSequence_liveRowsStayLast() {
        let bridge = makeRaw(id: "bridge-ns-aaaa-5")
        let liveUser = makeRaw(id: "UUID-USER", role: .user)
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: [],
            finalOrder: [],
            retainedRows: [liveUser, bridge],
            rowById: [:],
            segmentRanks: ["aaaa": 0]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["bridge-ns-aaaa-5", "UUID-USER"],
                       "live UUID 行 = 历史尚未承载的新内容，恒最后")
    }

    func test_orderedRowSequence_unifiedOrderWinsInMiddle() {
        let r1 = makeRaw(id: "bridge-ns-aaaa-1")
        let r2 = makeRaw(id: "bridge-ns-aaaa-2")
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: ["bridge-ns-aaaa-2", "bridge-ns-aaaa-1"],
            finalOrder: [r1, r2],
            retainedRows: [],
            rowById: [r1.id: r1, r2.id: r2],
            segmentRanks: ["aaaa": 0]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["bridge-ns-aaaa-2", "bridge-ns-aaaa-1"],
                       "unified 序（bridge history 序）是主体，段级定序只管不在序里的行")
    }

    // MARK: - deltaInsertIsSafe（[Fix v1.14.30] 混合批次形态闸）

    func test_deltaInsertIsSafe_singleTurnTail() {
        // [U2(认领), R2(插入)] —— 插入行全在最后认领行之后 → 安全（快路径）
        XCTAssertTrue(RemoteHistorySyncCore.deltaInsertIsSafe(
            unifiedFinalOrderIds: ["UUID-U2", "bridge-ns-aaaa-6"],
            inserts: [makeRaw(id: "bridge-ns-aaaa-6")]
        ))
    }

    func test_deltaInsertIsSafe_multiTurnSandwichRejected() {
        // [U2(认领), R2(插入), U3(认领)] —— R2 位于最后认领行 U3 之前 →
        // 单一锚点会把 R2 整批排到 U3 之后 = 错序 → 必须拒绝
        XCTAssertFalse(RemoteHistorySyncCore.deltaInsertIsSafe(
            unifiedFinalOrderIds: ["UUID-U2", "bridge-ns-aaaa-6", "UUID-U3"],
            inserts: [makeRaw(id: "bridge-ns-aaaa-6")]
        ))
    }

    func test_deltaInsertIsSafe_replyTailBeforeClaimedInputRejected() {
        // [R2(插入·上轮回复尾段), U3(认领)] —— 锚点取 U3 会把 R2 排到
        // U3 之后（真实序：R2 属上一回合，应在其前）→ 必须拒绝
        XCTAssertFalse(RemoteHistorySyncCore.deltaInsertIsSafe(
            unifiedFinalOrderIds: ["bridge-ns-aaaa-5", "UUID-U3"],
            inserts: [makeRaw(id: "bridge-ns-aaaa-5")]
        ))
    }

    func test_deltaInsertIsSafe_allInsertsNoClaim() {
        // 全是插入行（无认领行）→ 锚点 = 最后回放行，wire 序即目标序 → 安全
        XCTAssertTrue(RemoteHistorySyncCore.deltaInsertIsSafe(
            unifiedFinalOrderIds: ["bridge-ns-aaaa-6", "bridge-ns-aaaa-7"],
            inserts: [makeRaw(id: "bridge-ns-aaaa-6"), makeRaw(id: "bridge-ns-aaaa-7")]
        ))
    }

    func test_deltaInsertIsSafe_noInserts() {
        // 纯认领（无插入行）→ 无从错序 → 安全
        XCTAssertTrue(RemoteHistorySyncCore.deltaInsertIsSafe(
            unifiedFinalOrderIds: ["UUID-U2", "UUID-U3"],
            inserts: []
        ))
    }
}
