import XCTest
@testable import RemoteHistoryKit

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


// MARK: - [dup-drift fix 2026-09-14] WireUuidHoist 提升语义
final class WireUuidHoistTests: XCTestCase {
    /// messageUuid 已存在 → 原样胜出（不覆盖已有值，与 D12 注入同规则）。
    func test_existingMessageUuidWins() {
        XCTAssertEqual(
            WireUuidHoist.hoist(messageUuid: "m-1", userMessageUuid: "u-2"), "m-1")
    }
    /// messageUuid 缺失 → userMessageUuid 提升（raw history 的 tool_result 形态）。
    func test_userUuidHoistedWhenAbsent() {
        XCTAssertEqual(
            WireUuidHoist.hoist(messageUuid: nil, userMessageUuid: "u-2"), "u-2")
    }
    /// 空串 = 缺失（桥 additive 字段可能下发 ""，不能当身份）。
    func test_emptyStringsCountAsAbsent() {
        XCTAssertNil(WireUuidHoist.hoist(messageUuid: "", userMessageUuid: ""))
        XCTAssertEqual(
            WireUuidHoist.hoist(messageUuid: "", userMessageUuid: "u-2"), "u-2")
    }
    /// 双 nil → nil（旧桥无 uuid，走 bridge-{seq} 原路径，零行为变化）。
    func test_bothNilStaysNil() {
        XCTAssertNil(WireUuidHoist.hoist(messageUuid: nil, userMessageUuid: nil))
    }
    /// 核心回归：同一条 tool_result 经 entries（顶层 uuid）与 raw history
    /// （body userMessageUuid）两路到达必须收敛到同一身份 → 幂等 upsert。
    func test_bothDeliveryPathsConverge() {
        let viaEntries = WireUuidHoist.hoist(messageUuid: "u-9", userMessageUuid: nil)
        let viaRaw = WireUuidHoist.hoist(messageUuid: nil, userMessageUuid: "u-9")
        XCTAssertEqual(viaEntries, viaRaw)
    }
}

// MARK: - [S1a 2026-09-14] 回放池强身份互认（形态升级的认领侧）
//
// 事故形态：桥对同一 wire 条目的 uuid 原位变异（gen→real 回填、两路先后入库），
// 旧形态 bm-{G} 已在库、快照又发 bm-{R} → 主键互不相识 → 双行 + 旧行 miss
// serverIdSet 被甩头。回放池让两条形态**互认**（只认 toolUseId/clientMessageId，
// 不认文本——内容级配对是 09-11 对抗审查明文否决的）。

final class ReplayPoolIdentityTests: XCTestCase {

    private func row(_ id: String, role: MessageRole = .user, parts: [ContentPart],
                     cmid: String? = nil) -> RawMessage {
        RemoteHistoryFixture.row(id: id, role: role, parts: parts, clientMessageId: cmid)
    }
    private func tr(_ tu: String) -> ContentPart { RemoteHistoryFixture.toolResult(id: tu) }
    private func tu(_ id: String) -> ContentPart { RemoteHistoryFixture.toolUse(id: id) }

    func test_assistantReplay_hitsOldFormInDb() {
        // assistant 回放行原本直通 .unmatched（插入 → 与库里旧形态双份）。
        let g = row("bm-g", role: .assistant, parts: [tu("call-1")])
        var index = RemoteHistoryOwnerIndex(dbRows: [g], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-r", role: .assistant, parts: [tu("call-1")])),
                       .owner("bm-g"), "同一 tool_use 的两种 uuid 形态必须互认")
    }

    func test_assistantReplay_neverClaimsLiveAssistantRow() {
        // live 承载行不进回放池：assistant 的 live↔回放配对由 Reconciler 的
        // 回合吸收负责（删 live 插权威行），认领侧不得抢这条分工。
        let live = row("UUID-A", role: .assistant, parts: [tu("call-1")])
        var index = RemoteHistoryOwnerIndex(dbRows: [live], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-x", role: .assistant, parts: [tu("call-1")])),
                       .unmatched)
    }

    func test_userRow_livePoolWinsOverReplayPool() {
        // 三形态并存（L live 承载 + G 旧回放 + R 快照）：live 池必须先命中，
        // 否则升级插入的 R 会与 L 双份（行为回退）。
        let l = row("UUID-L", parts: [tr("call-1")])
        let g = row("bm-g", parts: [tr("call-1")])
        var index = RemoteHistoryOwnerIndex(dbRows: [l, g], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-r", parts: [tr("call-1")])),
                       .owner("UUID-L"))
    }

    func test_userRow_replayPoolUpgradesWhenNoLiveOwner() {
        let g = row("bm-g", parts: [tr("call-1")])
        var index = RemoteHistoryOwnerIndex(dbRows: [g], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-r", parts: [tr("call-1")])), .owner("bm-g"))
    }

    func test_selfForm_notConsumed() {
        // 快照重放**同一条**旧形态（桥还没回填）：owner==raw.id → 不算互认、
        // 不消费 claimedRowIds，走原分支幂等在位。
        let g = row("bm-g", parts: [tr("call-1")])
        var index = RemoteHistoryOwnerIndex(dbRows: [g], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: g), .unmatched)
    }

    func test_secondUpgradeCandidateIsDuplicate() {
        let g = row("bm-g", parts: [tr("call-1")])
        var index = RemoteHistoryOwnerIndex(dbRows: [g], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-r1", parts: [tr("call-1")])), .owner("bm-g"))
        XCTAssertEqual(index.claimOwner(for: row("bm-r2", parts: [tr("call-1")])), .duplicate,
                       "同一旧形态已被一条新形态认领，第二条同身份行=超录，丢弃")
    }

    func test_textNeverEntersReplayPool() {
        let g = row("bm-g", role: .assistant, parts: [.text("你好")])
        var index = RemoteHistoryOwnerIndex(dbRows: [g], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-r", role: .assistant, parts: [.text("你好")])),
                       .unmatched, "文本键不得进回放池——跨回合同文本误认必爆")
    }

    func test_clientMessageIdWorksInReplayPool() {
        let g = row("bm-g", parts: [.text("看图")], cmid: "c-1")
        var index = RemoteHistoryOwnerIndex(dbRows: [g], excluding: [], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-r", parts: [.text("看图")], cmid: "c-1")),
                       .owner("bm-g"))
    }

    func test_rowsScheduledForDeletion_notPooled() {
        let g = row("bm-g", parts: [tr("call-1")])
        var index = RemoteHistoryOwnerIndex(dbRows: [g], excluding: ["bm-g"], formUpgradePool: true)
        XCTAssertEqual(index.claimOwner(for: row("bm-r", parts: [tr("call-1")])), .unmatched)
    }
}
