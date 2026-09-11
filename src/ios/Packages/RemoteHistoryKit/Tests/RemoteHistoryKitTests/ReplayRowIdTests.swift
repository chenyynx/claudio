import XCTest
@testable import RemoteHistoryKit

/// ReplayRowId 的行为锁定（[Fix v1.14.29] 命名空间 + [Fix v1.14.30] 段身份）。
///
/// 背景：`messages.id` 是**全局**主键，而回放 id 曾用裸 `bridge-{seq}`——
/// seq 只在单个 bridge 会话内唯一 → 撞主键 → INSERT 失败 → 工具卡片/思考/
/// 正文被吞（pp 真机 2026-09-11 08:06：bridge-8/9/1 UNIQUE constraint failed）。
/// v1.14.30 再编入两个"段"：bridge 段（seq 空间所有者）与 disk 段（claude
/// 磁盘 transcript 所有者）——同一 chat 被 iCloud 同步到两台设备时，各设备各
/// 持不同 bridge 会话/不同 transcript，不带段仍会同 id 不同内容（LWW 串台）。
///
/// 本文件锁死：id 形态、三代旧形态解析、幂等迁移映射、迁移守卫（外来段/外来
/// 命名空间不改写）、兜底降级链。
final class ReplayRowIdTests: XCTestCase {

    // MARK: - 命名空间与段

    func test_namespace_usesSessionIdPrefixWithoutDash() {
        let ns = ReplayRowId.namespace(sessionId: "F5FD19FD-D052-47FE-989D-078E0EC7EB1E")
        XCTAssertEqual(ns, "F5FD19FD")
        XCTAssertFalse(ns.contains("-"),
                       "ns 不得含 '-'——解析按 '-' 切分取段/末段")
    }

    func test_segment_takesFirstEightChars() {
        XCTAssertEqual(ReplayRowId.segment(id: "43db1176"), "43db1176")
        XCTAssertEqual(ReplayRowId.segment(id: "43db1176-extra"), "43db1176",
                       "段取前 8 位（线上 bridgeId / claudeId 均按前 8 位建段）")
    }

    func test_bridgeId_carriesNamespaceAndSegment() {
        XCTAssertEqual(
            ReplayRowId.bridge(seq: 8, namespace: "abc12345", segment: "43db1176"),
            "bridge-abc12345-43db1176-8"
        )
        XCTAssertEqual(
            ReplayRowId.past(index: 3, namespace: "abc12345", diskSegment: "9f3e2a1b"),
            "past-abc12345-9f3e2a1b-3"
        )
    }

    func test_bridgeId_degradesWhenPartsMissing() {
        XCTAssertEqual(ReplayRowId.bridge(seq: 8, namespace: "abc12345", segment: nil), "bridge-abc12345-8",
                       "缺段 → v1.14.29 形态（兜底）")
        XCTAssertEqual(ReplayRowId.bridge(seq: 8, namespace: nil, segment: "43db1176"), "bridge-8",
                       "缺 ns → 最保守形态（兜底）")
        XCTAssertEqual(ReplayRowId.past(index: 3, namespace: "abc12345", diskSegment: nil), "past-abc12345-3")
        XCTAssertEqual(ReplayRowId.past(index: 3, namespace: nil, diskSegment: nil), "past-3")
    }

    // MARK: - 解析（三代形态都必须兼容）

    func test_parseBridgeSeq_allShapes() {
        XCTAssertEqual(ReplayRowId.parseBridgeSeq("bridge-8"), 8)
        XCTAssertEqual(ReplayRowId.parseBridgeSeq("bridge-abc12345-8"), 8)
        XCTAssertEqual(ReplayRowId.parseBridgeSeq("bridge-abc12345-43db1176-17"), 17,
                       "多位数 seq 不得被截断")
    }

    func test_parseBridgeSeq_rejectsNonBridgeRows() {
        XCTAssertNil(ReplayRowId.parseBridgeSeq("past-3"))
        XCTAssertNil(ReplayRowId.parseBridgeSeq("FD0BBE1C-9F96-4943-A"))
        XCTAssertNil(ReplayRowId.parseBridgeSeq("bridge-abc12345"))  // 末段非数字
    }

    func test_parseSegment_onlyForSegmentedShape() {
        XCTAssertEqual(ReplayRowId.parseSegment("bridge-abc12345-43db1176-8"), "43db1176")
        XCTAssertNil(ReplayRowId.parseSegment("bridge-abc12345-8"),
                     "v1.14.29 形态无段——必须返回 nil（迁移据此判定）")
        XCTAssertNil(ReplayRowId.parseSegment("bridge-8"))
        XCTAssertNil(ReplayRowId.parseSegment("past-abc12345-0"))
    }

    func test_parseDiskSegment_onlyForSegmentedPastShape() {
        XCTAssertEqual(ReplayRowId.parseDiskSegment("past-abc12345-9f3e2a1b-3"), "9f3e2a1b")
        XCTAssertNil(ReplayRowId.parseDiskSegment("past-abc12345-3"),
                     "v1.14.29 形态无 disk 段——返回 nil（迁移据此判定）")
        XCTAssertNil(ReplayRowId.parseDiskSegment("past-3"))
        XCTAssertNil(ReplayRowId.parseDiskSegment("bridge-abc12345-43db1176-8"))
    }

    func test_parseNamespace_availableForBothBridgeShapes() {
        XCTAssertEqual(ReplayRowId.parseNamespace("bridge-abc12345-43db1176-8"), "abc12345")
        XCTAssertEqual(ReplayRowId.parseNamespace("bridge-abc12345-8"), "abc12345")
        XCTAssertNil(ReplayRowId.parseNamespace("bridge-8"))
        XCTAssertNil(ReplayRowId.parseNamespace("past-abc12345-0"))
    }

    func test_parsePastIndex_bothShapes() {
        XCTAssertEqual(ReplayRowId.parsePastIndex("past-0"), 0)
        XCTAssertEqual(ReplayRowId.parsePastIndex("past-abc12345-0"), 0)
        XCTAssertEqual(ReplayRowId.parsePastIndex("past-abc12345-9f3e2a1b-12"), 12)
        XCTAssertNil(ReplayRowId.parsePastIndex("bridge-8"))
    }

    func test_isReplayRow_coversAllShapesRejectsUUID() {
        XCTAssertTrue(ReplayRowId.isReplayRow("bridge-8"))
        XCTAssertTrue(ReplayRowId.isReplayRow("bridge-abc12345-8"))
        XCTAssertTrue(ReplayRowId.isReplayRow("bridge-abc12345-43db1176-8"))
        XCTAssertTrue(ReplayRowId.isReplayRow("past-0"))
        XCTAssertTrue(ReplayRowId.isReplayRow("past-abc12345-9f3e2a1b-0"))
        XCTAssertFalse(ReplayRowId.isReplayRow("FD0BBE1C-9F96-4943-A"),
                       "live UUID 行不是回放行——renumber 分流/删除靶子都依赖这条")
    }

    // MARK: - 迁移映射（三代旧形态 → 目标形态，幂等）

    func test_migrationTarget_fromBareSeqShape() {
        XCTAssertEqual(
            ReplayRowId.migrationTarget(
                from: "bridge-8", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            ),
            "bridge-abc12345-43db1176-8"
        )
    }

    func test_migrationTarget_fromNamespaceOnlyShape() {
        XCTAssertEqual(
            ReplayRowId.migrationTarget(
                from: "bridge-abc12345-8", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            ),
            "bridge-abc12345-43db1176-8",
            "v1.14.29 形态必须再补段——前缀 LIKE 判定会漏掉它，形态判定只能靠解析"
        )
    }

    func test_migrationTarget_pastRowsGetDiskSegment() {
        XCTAssertEqual(
            ReplayRowId.migrationTarget(
                from: "past-0", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            ),
            "past-abc12345-9f3e2a1b-0"
        )
        XCTAssertEqual(
            ReplayRowId.migrationTarget(
                from: "past-abc12345-0", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            ),
            "past-abc12345-9f3e2a1b-0",
            "v1.14.29 的 past 形态（无 disk 段）必须再补段"
        )
    }

    func test_migrationTarget_pastRowsNeedDiskSegment() {
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "past-0", namespace: "abc12345", segment: "43db1176", diskSegment: nil
            ),
            "磁盘段未知时不动 past 行（补不了段）；留给下次带上再迁"
        )
    }

    func test_migrationTarget_idempotentForTargetShape() {
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "bridge-abc12345-43db1176-8", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            ),
            "已是目标形态 → nil，否则每次校准都重复改名"
        )
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "past-abc12345-9f3e2a1b-0", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            ),
            "past 目标形态同样幂等"
        )
    }

    /// [对抗审查 2026-09-11 高危1] 已带段的 bridge 行**一律不改写**：
    /// `bridge-{ns}-{别的段}-{seq}` 可能是别的设备/更早会话的行，改写成
    /// "当前段"会让它的内容顶替当前 seq（串台），甚至因目标 id 已存在而被
    /// 静默删除。这条断言正是那个缺陷的回归闸门。
    func test_migrationTarget_neverRewritesRowsThatAlreadyCarrySegment() {
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "bridge-abc12345-aaaaaaaa-5", namespace: "abc12345", segment: "bbbbbbbb", diskSegment: "9f3e2a1b"
            ),
            "别的段的 bridge 行不得被改写成本次 fetch 的段"
        )
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "past-abc12345-11111111-5", namespace: "abc12345", segment: "bbbbbbbb", diskSegment: "22222222"
            ),
            "别的 disk 段的 past 行同理"
        )
    }

    /// 外来命名空间的行不是本会话的——不改写（改了就跨会话串台）。
    func test_migrationTarget_neverRewritesForeignNamespace() {
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "bridge-deadbeef-5", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            )
        )
    }

    func test_migrationTarget_skipsBridgeRowsWithoutSegment() {
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "bridge-8", namespace: "abc12345", segment: nil, diskSegment: "9f3e2a1b"
            ),
            "段未知时不迁 bridge 行（补不了段）；留给下次带上段再迁"
        )
    }

    func test_migrationTarget_nilForNonReplayRows() {
        XCTAssertNil(
            ReplayRowId.migrationTarget(
                from: "FD0BBE1C-9F96-4943-A", namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
            )
        )
    }

    // MARK: - AgentMessage 集成（rawMessageId 单点派生）

    func test_rawMessageId_usesNamespaceAndSegment() {
        var msg = AgentMessage(role: .assistant, parts: [.text("x")])
        msg.bridgeSeq = 42
        msg.replayIdNamespace = "abc12345"
        msg.replayIdSegment = "43db1176"
        XCTAssertEqual(msg.rawMessageId(), "bridge-abc12345-43db1176-42")
    }

    func test_rawMessageId_legacyFallbackWithoutNamespace() {
        var msg = AgentMessage(role: .assistant, parts: [.text("x")])
        msg.bridgeSeq = 42
        XCTAssertEqual(msg.rawMessageId(), "bridge-42",
                       "无 ns 时保持旧形态（兜底路径），旧数据语义不变")
    }

    func test_historyAgentMessages_injectsNamespaceSegmentAndClientId() {
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old reply"}]},
         {"type":"user_input","text":"hi","clientMessageId":"cmid-1","historySeq":7,"sessionId":"s1"}]
        """
        let wire = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        let msgs = RemoteAgentProvider.historyAgentMessages(
            from: wire, namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
        )
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].dbMessageId, "past-abc12345-9f3e2a1b-0",
                       "past 行 id 必须带 disk 段（跨设备 transcript 不同，index 都从 0 起）")
        XCTAssertEqual(msgs[0].rawMessageId(), "past-abc12345-9f3e2a1b-0")
        XCTAssertNil(msgs[0].clientMessageId, "磁盘 past 行没有协议身份（只有 bridge 历史条目有）")
        XCTAssertEqual(msgs[1].rawMessageId(), "bridge-abc12345-43db1176-7")
        XCTAssertEqual(msgs[1].clientMessageId, "cmid-1",
                       "协议身份必须从 wire 带到 AgentMessage——校准期对账靠它")
    }

    func test_historyAgentMessages_degradesWithoutDiskSegment() {
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old reply"}]}]
        """
        let wire = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        let msgs = RemoteAgentProvider.historyAgentMessages(
            from: wire, namespace: "abc12345", segment: "43db1176", diskSegment: nil
        )
        XCTAssertEqual(msgs[0].dbMessageId, "past-abc12345-0",
                       "磁盘段缺失时退回 v1.14.29 形态（兜底链，不崩）")
    }
}
