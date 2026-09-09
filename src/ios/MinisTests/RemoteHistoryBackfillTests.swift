import XCTest
@testable import Minis

/// RemoteHistorySyncCore.planReplace 的行为锁定（v1.14.18 全量校准语义）。
///
/// 旧 BackfillCore（水位+指纹+增量 append）的 12 用例随该机制退役——
/// 它们锁定的是四个盲区所在的旧管线。新语义：bridge history 是唯一真相，
/// user 行全保留，非 user 行以 bridge-{seq} id 集为基准做集合校准。
final class RemoteHistoryBackfillTests: XCTestCase {

    // MARK: - Fixtures

    private func makeHistoryRaw(id: String, role: MessageRole, sortOrder: Int = 0) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: [.text("content-\(id)")],
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil
        )
    }

    private func makeDBRow(id: String, role: MessageRole, sortOrder: Int, errorInfo: String? = nil) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: [.text("db-\(id)")],
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: errorInfo
        )
    }

    // MARK: - planReplace

    func test_emptyDB_insertsEverything() {
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),
            makeHistoryRaw(id: "bridge-2", role: .assistant),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: [])
        XCTAssertEqual(plan.inserts.count, 2)
        XCTAssertTrue(plan.deleteIds.isEmpty)
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-1", "bridge-2"], "插入保持 history 原序")
    }

    func test_fullyInSync_noOp() {
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),
            makeHistoryRaw(id: "bridge-2", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "bridge-1", role: .user, sortOrder: 1),
            makeDBRow(id: "bridge-2", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertTrue(plan.inserts.isEmpty)
        XCTAssertTrue(plan.deleteIds.isEmpty)
        XCTAssertTrue(plan.isEmpty)
    }

    func test_liveUUIDAssistantRow_deleted() {
        // 杀后台前 live 落库的 assistant 行（UUID id）在重进校准时必须被删——
        // 它的内容已由 bridge-{seq} 行承载。这正是 v1.14.14/17 重复渲染的根源。
        let history = [makeHistoryRaw(id: "bridge-2", role: .assistant)]
        let db = [
            makeDBRow(id: "UUID-AAAA", role: .assistant, sortOrder: 1),
            makeDBRow(id: "UUID-BBBB", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-2"])
        XCTAssertEqual(Set(plan.deleteIds), ["UUID-AAAA", "UUID-BBBB"])
    }

    func test_liveUUIDUserRow_kept() {
        // user 行全保留：附件 XML 解析结果、errorInfo 等本地增强只在本地行上。
        let history = [makeHistoryRaw(id: "bridge-2", role: .assistant)]
        let db = [
            makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1),
            makeDBRow(id: "UUID-ASSIST", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertTrue(plan.inserts.contains { $0.id == "bridge-2" })
        XCTAssertEqual(plan.deleteIds, ["UUID-ASSIST"], "user 行永不删除")
        XCTAssertFalse(plan.deleteIds.contains("UUID-USER"))
    }

    func test_midSequenceGap_filled() {
        // 中段缺行补插：DB 有 bridge-1/bridge-3，history 是 1/2/3 → 只插 bridge-2。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),
            makeHistoryRaw(id: "bridge-2", role: .assistant),
            makeHistoryRaw(id: "bridge-3", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "bridge-1", role: .user, sortOrder: 1),
            makeDBRow(id: "bridge-3", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-2"])
        XCTAssertTrue(plan.deleteIds.isEmpty)
    }

    func test_toolResultHistoryRow_keptViaStableId() {
        // v1.14.18 修复核心：tool_result 回放行现在带 bridgeSeq → 稳定 id →
        // 重进校准命中 keep 集，不再每次全量重复落库（旧管线 DB 膨胀根源）。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .assistant),
            makeHistoryRaw(id: "bridge-2", role: .user), // tool_result 行 role=user
        ]
        let db = [
            makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 1),
            makeDBRow(id: "bridge-2", role: .user, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertTrue(plan.isEmpty)
    }

    func test_errorInfoSurvivesOnKeptRows() {
        // keep 语义 = 原行不动 → 本地 errorInfo 自然保留（plan 不复制行）。
        let history = [makeHistoryRaw(id: "bridge-1", role: .assistant)]
        let db = [makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 1, errorInfo: "stall")]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(db[0].errorInfo, "stall")
    }

    func test_historyOutOfOrder_stillIdBased() {
        // id 集合校准对 history 乱序不敏感（顺序由 finalOrder renumber 兜）。
        let history = [
            makeHistoryRaw(id: "bridge-3", role: .assistant),
            makeHistoryRaw(id: "bridge-1", role: .user),
        ]
        let db = [
            makeDBRow(id: "bridge-1", role: .user, sortOrder: 1),
            makeDBRow(id: "bridge-3", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertTrue(plan.isEmpty)
    }

    func test_duplicateHistoryIds_dedupedBySet() {
        // id 集合天然去重：同一 bridge-{seq} 出现两次不产生双插。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .assistant),
            makeHistoryRaw(id: "bridge-1", role: .assistant),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: [])
        XCTAssertEqual(plan.inserts.count, 2, "inserts 保留 history 序列（含重复项）；renumber 阶段由 finalOrder 统一定序，重复 id 由 DB 主键挡第二行")
    }

    // MARK: - isTurnInProgress（恢复态发送/停止键判定）

    func test_turnInProgress_byLastWireType() {
        XCTAssertTrue(RemoteHistorySyncCore.isTurnInProgress(lastWireType: "assistant"))
        XCTAssertTrue(RemoteHistorySyncCore.isTurnInProgress(lastWireType: "tool_result"))
        XCTAssertTrue(RemoteHistorySyncCore.isTurnInProgress(lastWireType: "user_input"))
        XCTAssertFalse(RemoteHistorySyncCore.isTurnInProgress(lastWireType: "result"))
        XCTAssertFalse(RemoteHistorySyncCore.isTurnInProgress(lastWireType: "error"))
        XCTAssertFalse(RemoteHistorySyncCore.isTurnInProgress(lastWireType: nil))
    }

    // MARK: - 防回归：id 派生策略（沿用旧套件的两条 pin 精神）

    func test_productionIdStrategy_usesBridgeSeq() {
        var withSeq = AgentMessage(role: .assistant, parts: [])
        withSeq.bridgeSeq = 42
        XCTAssertEqual(withSeq.rawMessageId(), "bridge-42",
                       "bridgeSeq 必须派生为稳定的 bridge-{seq}，否则校准 keep 集永不命中")

        var noSeq = AgentMessage(role: .assistant, parts: [])
        XCTAssertNotEqual(noSeq.rawMessageId(), noSeq.rawMessageId(),
                          "无 bridgeSeq 必须每次新 UUID（live-stream 路径）")
    }

    func test_toolResultReplay_injectsBridgeSeq() {
        // agentMessage(fromServer:) 的 tool_result 分支必须注入 historySeq ——
        // 漏注入 = UUID id = 每次校准全量重插（v1.14.18 修复的根因 3）。
        let json = """
        {"type":"tool_result","toolUseId":"toolu-1","toolName":"Bash","content":"ok","historySeq":7,"sessionId":"s1"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.bridgeSeq, 7, "tool_result 回放必须携带 bridgeSeq")
        XCTAssertEqual(agent?.rawMessageId(), "bridge-7")
    }

    func test_userInputReplay_converted() {
        // bridge 端 user turn 的 type 是 user_input（websocket.ts:3237）——
        // 旧代码落 default 分支整类丢弃（根因 3 之二）。
        let json = """
        {"type":"user_input","text":"hello world","historySeq":3,"sessionId":"s1"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent, "user_input 必须被转换，不得落入 default 丢弃")
        XCTAssertEqual(agent?.role, .user)
        XCTAssertEqual(agent?.bridgeSeq, 3)
        guard case .text(let t)? = agent?.parts.first else {
            return XCTFail("user_input 应转换为 .text part")
        }
        XCTAssertEqual(t, "hello world")
    }

    func test_assistantReplay_behaviorUnchanged() {
        // 防回归：assistant 转换的原有行为（blocks → parts + seq 注入）不变。
        let json = """
        {"type":"assistant","sessionId":"s1","historySeq":9,"message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a"}}]}}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.bridgeSeq, 9)
        XCTAssertEqual(agent?.parts.count, 2, "text + tool_use；thinking 进 reasoningContent")
        XCTAssertNotNil(agent?.reasoningContent)
    }
}
