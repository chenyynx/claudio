import XCTest
@testable import Minis

/// ReplayRowId 的行为锁定（[Fix v1.14.29] 回放行 id 命名空间）。
///
/// 背景：`messages.id` 是**全局**主键，而回放 id 曾用裸 `bridge-{seq}` /
/// `past-{index}`——seq 是 per-bridge-session 计数、past index 是每次 fetch
/// 的下标，两者都只在单个会话内唯一。两个本地会话各自同步过不同 bridge
/// 会话时同名 id 撞主键 → INSERT 直接失败 → 工具卡片/思考/正文被吞
/// （pp 真机 2026-09-11 08:06：bridge-8/9/1 UNIQUE constraint failed）。
///
/// 本文件锁死：命名空间形态、新旧形态解析兼容、幂等迁移映射、UUID 兜底。
final class ReplayRowIdTests: XCTestCase {

    // MARK: - 命名空间

    func test_namespace_usesSessionIdPrefixWithoutDash() {
        let ns = ReplayRowId.namespace(sessionId: "F5FD19FD-D052-47FE-989D-078E0EC7EB1E")
        XCTAssertEqual(ns, "F5FD19FD")
        XCTAssertFalse(ns.contains("-"),
                       "ns 不得含 '-'——parseBridgeSeq 按 '-' 切分取末段，ns 带 '-' 会解析错")
    }

    func test_bridgeAndPastIds_carryNamespace() {
        XCTAssertEqual(ReplayRowId.bridge(seq: 8, namespace: "abc12345"), "bridge-abc12345-8")
        XCTAssertEqual(ReplayRowId.past(index: 3, namespace: "abc12345"), "past-abc12345-3")
    }

    func test_nilOrEmptyNamespace_fallsBackToLegacyShape() {
        XCTAssertEqual(ReplayRowId.bridge(seq: 8, namespace: nil), "bridge-8")
        XCTAssertEqual(ReplayRowId.past(index: 3, namespace: nil), "past-3")
        XCTAssertEqual(ReplayRowId.bridge(seq: 8, namespace: ""), "bridge-8")
        XCTAssertEqual(ReplayRowId.past(index: 3, namespace: ""), "past-3")
    }

    // MARK: - 解析（新旧形态都必须兼容）

    func test_parseBridgeSeq_bothShapes() {
        XCTAssertEqual(ReplayRowId.parseBridgeSeq("bridge-8"), 8)
        XCTAssertEqual(ReplayRowId.parseBridgeSeq("bridge-abc12345-8"), 8)
        XCTAssertEqual(ReplayRowId.parseBridgeSeq("bridge-abc12345-17"), 17,
                       "命名空间后仍是末段数字——多位数不能被截断")
    }

    func test_parseBridgeSeq_rejectsNonBridgeRows() {
        XCTAssertNil(ReplayRowId.parseBridgeSeq("past-3"))
        XCTAssertNil(ReplayRowId.parseBridgeSeq("FD0BBE1C-9F96-4943-A"))
        XCTAssertNil(ReplayRowId.parseBridgeSeq("bridge-abc12345"))  // 末段非数字
    }

    func test_parsePastIndex_bothShapes() {
        XCTAssertEqual(ReplayRowId.parsePastIndex("past-0"), 0)
        XCTAssertEqual(ReplayRowId.parsePastIndex("past-abc12345-0"), 0)
        XCTAssertNil(ReplayRowId.parsePastIndex("bridge-8"))
    }

    func test_isReplayRow_coversBothPrefixesRejectsUUID() {
        XCTAssertTrue(ReplayRowId.isReplayRow("bridge-8"))
        XCTAssertTrue(ReplayRowId.isReplayRow("bridge-abc12345-8"))
        XCTAssertTrue(ReplayRowId.isReplayRow("past-0"))
        XCTAssertTrue(ReplayRowId.isReplayRow("past-abc12345-0"))
        XCTAssertFalse(ReplayRowId.isReplayRow("FD0BBE1C-9F96-4943-A"),
                       "live UUID 行不是回放行——renumber 分流/删除靶子都依赖这条")
    }

    // MARK: - 迁移映射（一次性、幂等）

    func test_migrationTarget_legacyToNamespaced() {
        XCTAssertEqual(ReplayRowId.migrationTarget(from: "bridge-8", namespace: "abc12345"),
                       "bridge-abc12345-8")
        XCTAssertEqual(ReplayRowId.migrationTarget(from: "past-0", namespace: "abc12345"),
                       "past-abc12345-0")
    }

    func test_migrationTarget_idempotentForMigratedRows() {
        XCTAssertNil(ReplayRowId.migrationTarget(from: "bridge-abc12345-8", namespace: "abc12345"),
                     "已命名空间化的行必须返回 nil——否则每次校准都会重复改名")
        XCTAssertNil(ReplayRowId.migrationTarget(from: "past-abc12345-0", namespace: "abc12345"))
    }

    func test_migrationTarget_nilForNonReplayRows() {
        XCTAssertNil(ReplayRowId.migrationTarget(from: "FD0BBE1C-9F96-4943-A", namespace: "abc12345"),
                     "live UUID 行不参与迁移")
    }

    // MARK: - AgentMessage 集成（rawMessageId 单点派生）

    func test_rawMessageId_usesNamespaceWhenPresent() {
        var msg = AgentMessage(role: .assistant, parts: [.text("x")])
        msg.bridgeSeq = 42
        msg.replayIdNamespace = "abc12345"
        XCTAssertEqual(msg.rawMessageId(), "bridge-abc12345-42",
                       "回放路径必须带命名空间——不带就会跨会话撞全局主键")
    }

    func test_rawMessageId_legacyFallbackWithoutNamespace() {
        var msg = AgentMessage(role: .assistant, parts: [.text("x")])
        msg.bridgeSeq = 42
        XCTAssertEqual(msg.rawMessageId(), "bridge-42",
                       "无 ns 时保持旧形态（兜底路径），既有测试/旧数据语义不变")
    }

    func test_historyAgentMessages_injectsNamespaceForBridgeAndPastRows() {
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old reply"}]},
         {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"live reply"}]},"historySeq":7,"sessionId":"s1"}]
        """
        let wire = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        let msgs = RemoteAgentProvider.historyAgentMessages(from: wire, namespace: "abc12345")
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].dbMessageId, "past-abc12345-0")
        XCTAssertEqual(msgs[0].rawMessageId(), "past-abc12345-0")
        XCTAssertEqual(msgs[1].rawMessageId(), "bridge-abc12345-7",
                       "回放 assistant 行同样带命名空间")
    }
}
