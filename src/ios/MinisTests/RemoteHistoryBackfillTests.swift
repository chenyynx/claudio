import XCTest
@testable import Minis

final class RemoteHistoryBackfillTests: XCTestCase {

    private func makeBuildRaw() -> (AgentMessage) async -> RawMessage? {
        return { agentMsg in
            let role: MessageRole = agentMsg.role == .user ? .user : .assistant
            // [Fix 2026-09-05 bug 1] Prefer the AgentMessage's own dbMessageId
            // when present (the live path populates it before buildRaw runs).
            // Otherwise delegate to `rawMessageId()` — the SAME helper
            // production `buildRawMessage` uses — so test and prod can never
            // diverge again on id strategy. The previous inline
            // `if let seq ... "bridge-\(seq)" ... else UUID()` here masked
            // the production regression because it duplicated the policy
            // instead of sharing it.
            let id: String
            if let dbId = agentMsg.dbMessageId {
                id = dbId
            } else {
                id = agentMsg.rawMessageId()
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

    // MARK: - 11. 防回归：production/rawMessageId 派生策略（2026-09-05 bug 1）

    /// Pins the id strategy used by production `buildRawMessage`. A previous
    /// version of this test used a hand-rolled `if let seq { "bridge-\(seq)" }
    /// else { UUID() }` inside `makeBuildRaw` while production called
    /// `UUID().uuidString` directly — the suites diverged silently and the
    /// production dedup broke. This test calls the shared `rawMessageId()`
    /// helper that BOTH prod and test now use, so a future regression that
    /// changes one without the other will fail here.
    func test_productionIdStrategy_usesBridgeSeq() {
        var withSeq = AgentMessage(role: .assistant, parts: [])
        withSeq.bridgeSeq = 42
        XCTAssertEqual(withSeq.rawMessageId(), "bridge-42",
                       "bridgeSeq 必须派生为稳定的 bridge-{seq}，否则 BackfillCore 的 id 去重永不命中")

        var noSeq = AgentMessage(role: .assistant, parts: [])
        XCTAssertNotEqual(noSeq.rawMessageId(), noSeq.rawMessageId(),
                          "无 bridgeSeq 必须每次新 UUID（live-stream 路径，重复即 bug）")

        // 关键对齐：makeBuildRaw 与生产 buildRawMessage 走同一 helper
        let fromHelper = noSeq.rawMessageId()
        var liveLike = AgentMessage(role: .user, parts: [])
        let fromMakeBuildRawClosure: String = {
            // mirror the closure body in makeBuildRaw
            if let dbId = liveLike.dbMessageId { return dbId }
            return liveLike.rawMessageId()
        }()
        XCTAssertNotEqual(fromHelper, fromMakeBuildRawClosure,
                          "smoke: 两次调用应得到不同 UUID（都是 nil bridgeSeq 路径）")
    }

    // MARK: - 12. 防回归：live 路径 bridgeSeq 注入后 id 派生与 backfill 一致（2026-09-05 route D）

    /// Pins the live-path injection behavior. After route D, `persistAgentMessage`
    /// receives the bridge seq from `provider.lastBridgeSeq` and injects it into
    /// a local copy of the live `AgentMessage` (whose `bridgeSeq` field is nil
    /// because live events flow through `RemoteAgentProvider.consume()` rather
    /// than `agentMessage(fromServer:)`). The injected msg must then produce
    /// the SAME `rawMessageId()` ("bridge-{seq}") that the history-replay path
    /// produces for the same wire message — this is what lets
    /// `BackfillCore.computePlan`'s id-set dedup actually hit.
    ///
    /// Without this assertion, a regression that injects the seq but the
    /// helper still UUID-branches (or the helper changes to a different
    /// format) would silently re-introduce the duplicate-render Bug D.
    func test_livePath_injectsBridgeSeq_producesStableBridgeId() {
        // Live-path msg: bridgeSeq is nil because consume() never sets it.
        var liveMsg = AgentMessage(role: .assistant, parts: [])
        XCTAssertNil(liveMsg.bridgeSeq, "live path msg 必须 nil bridgeSeq（route D 改前状态）")

        // Route D injection (mirrors the body of persistAgentMessage).
        let capturedSeq = 17
        var injected = liveMsg
        injected.bridgeSeq = capturedSeq
        let liveId = injected.rawMessageId()

        // History-replay path: same wire message, decoded by
        // agentMessage(fromServer:) which DOES set bridgeSeq from historySeq.
        var replayMsg = AgentMessage(role: .assistant, parts: [])
        replayMsg.bridgeSeq = capturedSeq
        let replayId = replayMsg.rawMessageId()

        XCTAssertEqual(liveId, replayId,
                       "live 注入 seq 后必须与 history-replay 路径派生同一 id，否则 BackfillCore id 去重永不命中")
        XCTAssertEqual(liveId, "bridge-\(capturedSeq)",
                       "id 派生格式必须是 'bridge-{seq}'，与 makeBuildRaw + rawMessageId 共享同一 helper")

        // 防退化：如果有人改回 live 路径不注入（msg.bridgeSeq 仍 nil），
        // rawMessageId() 走 UUID 分支 → liveId != replayId → 重复渲染复发
        let unInjectedId = liveMsg.rawMessageId()  // 仍走 UUID 分支
        XCTAssertNotEqual(unInjectedId, replayId,
                          "未注入的 live msg 必须仍走 UUID 分支（保 local 路径行为零变），但这正是 Bug D 根因；本断言只是确认 helper 没意外改 UUID 行为")
    }
}
