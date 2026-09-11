import XCTest
@testable import Minis

/// [Fix v1.14.29] 乱序根因 A 的两组新纯函数锁定。
///
/// 1. `deltaFastPathAllowed` —— 增量快路径闸门：delta 只含增量条目，把残缺
///    序喂给 renumber 会把用户全部发言甩到会话末尾（pp 真机 2026-09-11
///    08:06 实证）。准入 = 定序已封版 + 纯追加。
/// 2. 用户文本配对 —— 附件 XML 归一化（本地 parts=[xml,正文] vs bridge 侧
///    "正文\n\n"+XML）+ 同文本多 occurrence 队列配对（连发两条"在吗"）。
final class RemoteHistorySyncCoreDeltaTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRaw(id: String, role: MessageRole, text: String, sortOrder: Int = 0) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: [.text(text)],
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil
        )
    }

    private let attachmentXML = """
    <user-attached-files><file path="/tmp/a.png" size="1" modified="2026-09-11T00:00:00Z"/></user-attached-files>
    """

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

    // MARK: - 用户文本归一化（附件消息）

    func test_normalizedUserText_stripsAttachmentBlocks() {
        let raw = "看图\n\n\(attachmentXML)"
        XCTAssertEqual(RemoteHistorySyncCore.normalizedUserText(raw), "看图")
        XCTAssertEqual(
            RemoteHistorySyncCore.normalizedUserText("hi<attachment-failed file=\"x\" reason=\"y\"/>"),
            "hi"
        )
        XCTAssertEqual(RemoteHistorySyncCore.normalizedUserText("  plain  "), "plain")
        XCTAssertEqual(RemoteHistorySyncCore.normalizedUserText(attachmentXML), "",
                       "纯 XML → 空串（图片-only 消息不参与文本配对）")
    }

    func test_userTextMatchKey_skipsXMLOnlyPart() {
        let key = RemoteHistorySyncCore.userTextMatchKey(parts: [.text(attachmentXML), .text("看图")])
        XCTAssertEqual(key, "看图", "本地行 parts=[xml, 正文] → 必须取正文")
        XCTAssertNil(RemoteHistorySyncCore.userTextMatchKey(parts: [.text(attachmentXML)]),
                     "只有 XML → nil")
        XCTAssertNil(RemoteHistorySyncCore.userTextMatchKey(parts: []))
    }

    func test_planReplace_attachmentMessage_dedupedAfterStrip() {
        // 本地行 = [xml, 正文]；bridge 侧 user_input = "正文\n\n" + 同一 XML。
        // 旧实现按 parts.first 原文比对必然对不上 → 回放行重插（重复气泡）
        // + 本地行被 renumber 甩尾。
        let historyUser = makeRaw(id: "bridge-1", role: .user, text: "看图\n\n\(attachmentXML)")
        var local = makeRaw(id: "UUID-A", role: .user, text: "看图", sortOrder: 1)
        local.parts = [.text(attachmentXML), .text("看图")]

        let plan = RemoteHistorySyncCore.planReplace(historyRaws: [historyUser], dbRows: [local])
        XCTAssertTrue(plan.inserts.isEmpty, "归一化同文本 → 回放行不得重插")
        XCTAssertEqual(plan.unifiedFinalOrderIds, ["UUID-A"], "本地行顶替该 history 位置")
    }

    // MARK: - 同文本多 occurrence 配对

    func test_planReplace_duplicateUserTexts_pairByOccurrence() {
        // 连发两条 "在吗"：旧实现每段文本只留**第一个** owner → 第二个
        // history 行永远配不上（回放行被插成重复 + 第二条本地行被甩尾）。
        let history = [
            makeRaw(id: "bridge-1", role: .user, text: "在吗"),
            makeRaw(id: "bridge-2", role: .assistant, text: "在的"),
            makeRaw(id: "bridge-3", role: .user, text: "在吗"),
        ]
        let local1 = makeRaw(id: "UUID-A", role: .user, text: "在吗", sortOrder: 1)
        let local2 = makeRaw(id: "UUID-B", role: .user, text: "在吗", sortOrder: 2)

        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: [local1, local2])
        XCTAssertEqual(plan.unifiedFinalOrderIds, ["UUID-A", "bridge-2", "UUID-B"],
                       "两个同文本 owner 各占一个位置，不得重复用同一行")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-2"],
                       "两条 user 回放行都被本地行顶替，只有 assistant 行是真新增")
        XCTAssertTrue(plan.deleteIds.isEmpty, "user 行永不被删")
    }

    func test_planReplace_keptHistoryRow_doesNotShiftPairing() {
        // history 行已在 DB（keep 命中）时，同文本的**下一**个 occurrence
        // 仍应拿到第一个未被占用的本地行。
        let history = [
            makeRaw(id: "bridge-1", role: .user, text: "在吗"),
            makeRaw(id: "bridge-3", role: .user, text: "在吗"),
        ]
        let db = [
            makeRaw(id: "bridge-1", role: .user, text: "在吗", sortOrder: 1),  // 已在 DB
            makeRaw(id: "UUID-B", role: .user, text: "在吗", sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertEqual(plan.unifiedFinalOrderIds, ["bridge-1", "UUID-B"])
        XCTAssertTrue(plan.inserts.isEmpty)
    }
}
