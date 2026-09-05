import XCTest
@testable import Minis

final class RemoteHistoryBackfillTests: XCTestCase {

    private func makeBuildRaw() -> (AgentMessage) async -> RawMessage? {
        return { agentMsg in
            let role: MessageRole = agentMsg.role == .user ? .user : .assistant
            let id: String
            if let seq = agentMsg.bridgeSeq {
                id = "bridge-\(seq)"
            } else if let dbId = agentMsg.dbMessageId {
                id = dbId
            } else {
                id = UUID().uuidString
            }
            return RawMessage(
                id: id,
                sessionId: "test-session",
                role: role,
                parts: [],
                createdAt: Date(),
                tokenUsage: nil,
                reasoningContent: nil,
                streamInterruptCount: 0,
                sortOrder: 0,
                errorInfo: nil,
                uiSequence: nil
            )
        }
    }

    private func makeAgentMessage(role: AgentMessage.Role = .user, seq: Int? = nil) -> AgentMessage {
        var msg = AgentMessage(role: role, parts: [])
        msg.bridgeSeq = seq
        return msg
    }

    private func makeRawMessage(id: String) -> RawMessage {
        RawMessage(
            id: id,
            sessionId: "test-session",
            role: .user,
            parts: [],
            createdAt: Date(),
            tokenUsage: nil,
            reasoningContent: nil,
            streamInterruptCount: 0,
            sortOrder: 0,
            errorInfo: nil,
            uiSequence: nil
        )
    }

    // MARK: - 1. 空 history

    func test_emptyHistory_returnsEmpty() async {
        let plan = await BackfillCore.computePlan(history: [], existing: [], lastSyncedSeq: 0, buildRaw: makeBuildRaw())
        XCTAssertTrue(plan.newRaws.isEmpty)
        XCTAssertEqual(plan.skipCounters.seq, 0)
        XCTAssertEqual(plan.skipCounters.id, 0)
        XCTAssertEqual(plan.maxSeq, 0)
    }

    // MARK: - 2. 全部新消息

    func test_allNew() async {
        let history = [makeAgentMessage(seq: 1), makeAgentMessage(seq: 2), makeAgentMessage(seq: 3)]
        let plan = await BackfillCore.computePlan(history: history, existing: [], lastSyncedSeq: 0, buildRaw: makeBuildRaw())
        XCTAssertEqual(plan.newRaws.count, 3)
        XCTAssertEqual(plan.skipCounters.seq, 0)
        XCTAssertEqual(plan.maxSeq, 3)
    }

    // MARK: - 3. 全部已同步

    func test_allSkipped() async {
        let history = [makeAgentMessage(seq: 1), makeAgentMessage(seq: 2), makeAgentMessage(seq: 3)]
        let plan = await BackfillCore.computePlan(history: history, existing: [], lastSyncedSeq: 3, buildRaw: makeBuildRaw())
        XCTAssertTrue(plan.newRaws.isEmpty)
        XCTAssertEqual(plan.skipCounters.seq, 3)
        XCTAssertEqual(plan.maxSeq, 3)
    }

    // MARK: - 4. 部分混合

    func test_mixed() async {
        let history = [makeAgentMessage(seq: 1), makeAgentMessage(seq: 2), makeAgentMessage(seq: 3), makeAgentMessage(seq: 4), makeAgentMessage(seq: 5)]
        let plan = await BackfillCore.computePlan(history: history, existing: [], lastSyncedSeq: 3, buildRaw: makeBuildRaw())
        XCTAssertEqual(plan.newRaws.count, 2, "seq=4/5 应进 newRaws")
        XCTAssertEqual(plan.skipCounters.seq, 3, "seq=1/2/3 应被 skip")
        XCTAssertEqual(plan.maxSeq, 5)
    }

    // MARK: - 5. 缺 bridgeSeq 不被 seq 规则拦截

    func test_missingBridgeSeq_bypassesSeqRule() async {
        let history = [makeAgentMessage(seq: nil), makeAgentMessage(seq: 1)]
        let plan = await BackfillCore.computePlan(history: history, existing: [], lastSyncedSeq: 5, buildRaw: makeBuildRaw())
        XCTAssertEqual(plan.newRaws.count, 1)
        XCTAssertEqual(plan.skipCounters.seq, 1)
        XCTAssertEqual(plan.maxSeq, 5)
    }

    // MARK: - 6. id 二次去重

    func test_idDedup() async {
        let history = [makeAgentMessage(seq: 1), makeAgentMessage(seq: 2)]
        let existing = [makeRawMessage(id: "bridge-1"), makeRawMessage(id: "bridge-2")]
        let plan = await BackfillCore.computePlan(history: history, existing: existing, lastSyncedSeq: 0, buildRaw: makeBuildRaw())
        XCTAssertTrue(plan.newRaws.isEmpty)
        XCTAssertEqual(plan.skipCounters.id, 2)
    }

    // MARK: - 7. maxSeq 推进

    func test_maxSeq_advances() async {
        let history = [makeAgentMessage(seq: 5), makeAgentMessage(seq: 7), makeAgentMessage(seq: nil)]
        let plan = await BackfillCore.computePlan(history: history, existing: [], lastSyncedSeq: 3, buildRaw: makeBuildRaw())
        XCTAssertEqual(plan.newRaws.count, 2)
        XCTAssertEqual(plan.maxSeq, 7)
    }

    // MARK: - 8. buildRaw 返回 nil

    func test_buildRawReturnsNil() async {
        let history = [makeAgentMessage(seq: 1), makeAgentMessage(seq: 2)]
        let plan = await BackfillCore.computePlan(history: history, existing: [], lastSyncedSeq: 0, buildRaw: { _ in nil })
        XCTAssertTrue(plan.newRaws.isEmpty)
        XCTAssertEqual(plan.maxSeq, 2)
    }

    // MARK: - 9. 跨 session

    func test_crossSession() async {
        let buildRaw: (AgentMessage) async -> RawMessage? = { agentMsg in
            RawMessage(
                id: "msg-\(agentMsg.bridgeSeq ?? 0)",
                sessionId: "session-B",
                role: .user,
                parts: [],
                createdAt: Date(),
                tokenUsage: nil,
                reasoningContent: nil,
                streamInterruptCount: 0,
                sortOrder: 0,
                errorInfo: nil,
                uiSequence: nil
            )
        }
        let history = [makeAgentMessage(seq: 1)]
        let existing = [makeRawMessage(id: "msg-1")]
        let plan = await BackfillCore.computePlan(history: history, existing: existing, lastSyncedSeq: 0, buildRaw: buildRaw)
        XCTAssertEqual(plan.maxSeq, 1)
    }

    // MARK: - 10. lastSyncedSeq=0 全纳入

    func test_lastSyncedSeqZero() async {
        let history = [makeAgentMessage(seq: 1), makeAgentMessage(seq: 2), makeAgentMessage(seq: 100)]
        let plan = await BackfillCore.computePlan(history: history, existing: [], lastSyncedSeq: 0, buildRaw: makeBuildRaw())
        XCTAssertEqual(plan.newRaws.count, 3)
        XCTAssertEqual(plan.maxSeq, 100)
    }
}
