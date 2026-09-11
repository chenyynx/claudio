import XCTest
@testable import Minis

/// RemoteHistoryOwnerIndex 的行为锁定（[Fix v1.14.30] 身份对账）。
///
/// 校准期必须判定"这条 bridge 回放行是否已有本地行承载"。旧实现按正文猜：
/// 附件消息（本地 parts=[xml,正文] vs bridge "正文+XML"）、纯图片消息（无
/// 正文）、连发两条相同短消息都会猜错 → 重复气泡 / 本地行被甩到会话末尾。
/// 新实现按**协议身份** clientMessageId 优先，文本仅作老数据/旧 bridge 兜底。
final class RemoteHistoryIdentityTests: XCTestCase {

    // MARK: - Fixtures

    private let xml = """
    <user-attached-files><file path="/tmp/a.png" size="1" modified="2026-09-11T00:00:00Z"/></user-attached-files>
    """

    private func row(
        id: String,
        role: MessageRole = .user,
        parts: [ContentPart],
        clientMessageId: String? = nil,
        sortOrder: Int = 0
    ) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: parts, createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil, clientMessageId: clientMessageId
        )
    }

    private func toolResultRow(id: String, toolUseId: String) -> RawMessage {
        row(id: id, parts: [.toolResult(ToolResult(
            toolUseId: toolUseId, output: "ok", success: true, mediaRef: nil,
            snapshot: nil, pageURL: nil, status: "success", outputFile: nil
        ))])
    }

    // MARK: - clientMessageId 优先（协议身份）

    func test_claim_byClientMessageId_evenWhenTextDiffers() {
        // 附件消息：本地行 parts=[xml, 正文]，bridge 侧文本 = "正文\n\n"+XML。
        // 逐字比对必然不同——有协议身份就不该看文本。
        let local = row(id: "UUID-A", parts: [.text(xml), .text("看图")], clientMessageId: "cmid-1")
        let raw = row(id: "bridge-ns-seg-1", parts: [.text("看图\n\n\(xml)")], clientMessageId: "cmid-1")
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: raw), .owner("UUID-A"))
    }

    func test_claim_imageOnlyRow_byClientMessageId() {
        // v1.14.29 已知残余：纯图片消息无正文 → 归一化后为空 → 文本匹配必失败。
        let local = row(id: "UUID-IMG", parts: [.text(xml)], clientMessageId: "cmid-img")
        let raw = row(id: "bridge-ns-seg-2", parts: [.text(xml)], clientMessageId: "cmid-img")
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: raw), .owner("UUID-IMG"),
                       "纯图片行只能靠协议身份认领——这正是必须接 clientMessageId 的原因")
    }

    func test_claim_imageOnlyRow_withoutClientId_returnsNil() {
        let local = row(id: "UUID-IMG", parts: [.text(xml)])
        let raw = row(id: "bridge-ns-seg-2", parts: [.text(xml)])
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: raw), .unmatched, "无身份的纯图片行配不上（不猜）")
    }

    func test_claim_clientIdTakesPrecedenceOverText() {
        // 两行同文本，只有一行带协议身份：带身份的那行必须被身份命中，
        // 另一行留给文本兜底。
        let a = row(id: "UUID-A", parts: [.text("hi")], clientMessageId: "cmid-1", sortOrder: 1)
        let b = row(id: "UUID-B", parts: [.text("hi")], sortOrder: 2)
        var index = RemoteHistoryOwnerIndex(dbRows: [a, b], excluding: [])

        let rawWithId = row(id: "bridge-ns-seg-1", parts: [.text("hi")], clientMessageId: "cmid-1")
        XCTAssertEqual(index.claimOwner(for: rawWithId), .owner("UUID-A"))

        let rawWithoutId = row(id: "bridge-ns-seg-2", parts: [.text("hi")])
        XCTAssertEqual(index.claimOwner(for: rawWithoutId), .owner("UUID-B"),
                       "无身份回放行走文本兜底，且不得复用已被认领的 UUID-A")
    }

    // MARK: - 文本兜底（老行 / 旧 bridge）

    func test_claim_textFallback_normalizesAttachmentXML() {
        let local = row(id: "UUID-A", parts: [.text(xml), .text("看图")])
        let raw = row(id: "bridge-ns-seg-1", parts: [.text("看图\n\n\(xml)")])
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: raw), .owner("UUID-A"))
    }

    func test_claim_textFallback_pairsDuplicatesByOccurrence() {
        let a = row(id: "UUID-A", parts: [.text("在吗")], sortOrder: 1)
        let b = row(id: "UUID-B", parts: [.text("在吗")], sortOrder: 2)
        var index = RemoteHistoryOwnerIndex(dbRows: [a, b], excluding: [])
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-1", parts: [.text("在吗")])), .owner("UUID-A"))
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-3", parts: [.text("在吗")])), .owner("UUID-B"))
    }

    func test_claim_oneLocalRowClaimedOnce() {
        let local = row(id: "UUID-A", parts: [.text("在吗")])
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-1", parts: [.text("在吗")])), .owner("UUID-A"))
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-2", parts: [.text("在吗")])), .duplicate,
                       "[v1.14.31] 第二个回放行 = 同一逻辑消息的超录副本（watchdog 重试重发）→ 丢弃，不再插成重复气泡")
    }

    func test_claim_excludesRowsScheduledForDeletion() {
        // past id 空间迁移模式下，旧 past user 行会进 deleteIds：
        // 若仍进池，新序列同文本行会顶替一个"马上被删"的 id（旧行已删 +
        // 新行不插 = 用户消息净丢）。
        let doomed = row(id: "past-0", parts: [.text("在吗")])
        var index = RemoteHistoryOwnerIndex(dbRows: [doomed], excluding: ["past-0"])
        XCTAssertEqual(index.claimOwner(for: row(id: "past-1", parts: [.text("在吗")])), .unmatched)
    }

    // MARK: - toolUseId（工具结果行）

    func test_claim_toolResultByToolUseId() {
        let local = toolResultRow(id: "UUID-TR", toolUseId: "toolu-1")
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        let raw = toolResultRow(id: "bridge-ns-seg-5", toolUseId: "toolu-1")
        XCTAssertEqual(index.claimOwner(for: raw), .owner("UUID-TR"))
    }

    // MARK: - 不该认领的行

    func test_claim_assistantRowsNeverClaim() {
        let local = row(id: "UUID-A", role: .assistant, parts: [.text("hi")])
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-1", role: .assistant, parts: [.text("hi")])), .unmatched,
                       "assistant 回放行是内容本身，不是本地 user 行的化身")
    }

    func test_claim_emptyTextRowIsNotATextMatch() {
        let local = row(id: "UUID-A", parts: [.text("   ")])
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-1", parts: [.text("")])), .unmatched,
                       "空白文本不构成身份——否则任意空行互相顶替")
    }

    // MARK: - v1.14.31 F1：watchdog 重试重发（同一逻辑消息超录）

    func test_retryDoubleSend_secondReplayRowIsDuplicate() {
        // pp 真机 2026-09-11 实锤：120s 静默 → 自动重试重发「你好」→ bridge
        // 超录两条（首条 cmid-1，重试条带新 cmid）。本地只有一条承载行：
        // 首条按身份认领，第二条必须判 duplicate（丢弃），不得插成新气泡。
        let local = row(id: "UUID-A", parts: [.text("你好")], clientMessageId: "cmid-1")
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-1", parts: [.text("你好")], clientMessageId: "cmid-1")),
                       .owner("UUID-A"))
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-2", parts: [.text("你好")], clientMessageId: "cmid-2")),
                       .duplicate)
    }

    func test_retryDoubleSend_unrelatedTextStillInserts() {
        // 同文本但本地从未有过（其他设备/老会话回放）→ 照常插入，不误杀。
        let local = row(id: "UUID-A", parts: [.text("早")])
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: row(id: "bridge-ns-seg-1", parts: [.text("你好")])), .unmatched)
    }

    func test_retryDoubleSend_toolResultDuplicate() {
        // toolUseId 同理：同 id 的第二条 tool_result 回放行是重录副本。
        let local = toolResultRow(id: "UUID-TR", toolUseId: "toolu-1")
        var index = RemoteHistoryOwnerIndex(dbRows: [local], excluding: [])
        XCTAssertEqual(index.claimOwner(for: toolResultRow(id: "bridge-ns-seg-5", toolUseId: "toolu-1")), .owner("UUID-TR"))
        XCTAssertEqual(index.claimOwner(for: toolResultRow(id: "bridge-ns-seg-6", toolUseId: "toolu-1")), .duplicate)
    }
}
