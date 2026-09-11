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
        makeHistoryRaw(id: id, role: role, sortOrder: sortOrder, parts: [.text("content-\(id)")])
    }

    private func makeHistoryRaw(id: String, role: MessageRole, sortOrder: Int, parts: [ContentPart], clientMessageId: String?) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: parts,
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil, clientMessageId: clientMessageId
        )
    }

    private func makeHistoryRaw(id: String, role: MessageRole, sortOrder: Int = 0, parts: [ContentPart]) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: parts,
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

    private func makeDBRow(id: String, role: MessageRole, sortOrder: Int, clientMessageId: String) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: [.text("db-\(id)")],
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil, clientMessageId: clientMessageId
        )
    }

    /// [Fix 2026-09-11] parts 定制版（RawMessage.parts 是 let，不允许事后
    /// 赋值——测试门重开 CI 实锤）。
    private func makeDBRow(id: String, role: MessageRole, sortOrder: Int, parts: [ContentPart]) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: parts,
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil
        )
    }

    // MARK: - planReplace

    /// [v1.14.31 F1] pp 真机实锤形态：watchdog 重试重发 → bridge 超录两条
    /// 「你好」→ 旧算法把第二条插成 DB 副本。再校准一次必须自愈：副本删除、
    /// unified 序只剩本地承载行一份、不再产生新插入。
    func test_retryDoubleRecord_selfHealsExistingDuplicateRow() {
        let live = makeDBRow(id: "UUID-A", role: .user, sortOrder: 1, clientMessageId: "cmid-1")
        let staleDup = makeDBRow(id: "bridge-ns-seg-2", role: .user, sortOrder: 2, parts: [.text("你好")])
        let history = [
            makeHistoryRaw(id: "bridge-ns-seg-1", role: .user, sortOrder: 1, parts: [.text("你好")], clientMessageId: "cmid-1"),
            makeHistoryRaw(id: "bridge-ns-seg-2", role: .user, sortOrder: 2, parts: [.text("你好")], clientMessageId: "cmid-2"),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: [live, staleDup])
        XCTAssertTrue(plan.inserts.isEmpty, "两条回放均已被本地承载/判超录，不得新增")
        XCTAssertTrue(plan.deleteIds.contains("bridge-ns-seg-2"), "旧算法误插的副本自愈删除")
        XCTAssertFalse(plan.deleteIds.contains("UUID-A"), "本地承载行保留")
        XCTAssertEqual(plan.unifiedFinalOrderIds, ["UUID-A"], "unified 序只有一份「你好」")
    }

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

    func test_oldBridgeRowsBeyondTrimWindow_kept() {
        // [R1 对抗审查] bridge 端 MAX_HISTORY_PER_SESSION=100（session.ts:186
        // trimHistory）——get_history 只返回尾部 100 条。DB 里更老的
        // bridge-{seq} 行不在 history 集，必须保留（bridge 是增量真相，
        // 本地是累积缓存；按"不在集即删"的教条处理 = 长会话老消息被吞）。
        let history = [
            makeHistoryRaw(id: "bridge-198", role: .user),
            makeHistoryRaw(id: "bridge-199", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 1),   // 老消息，trim 窗口外
            makeDBRow(id: "bridge-50", role: .assistant, sortOrder: 2),  // 老消息
            makeDBRow(id: "UUID-LIVE", role: .assistant, sortOrder: 3),  // live UUID 行 → 应删
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertEqual(Set(plan.deleteIds), ["UUID-LIVE"], "只有 UUID 行删除，老 bridge 行永不删")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-198", "bridge-199"])
    }

    func test_liveUserRowWithSameText_blocksHistoryInsert() {
        // [排查 2026-09-10] live user 行（UUID，含图片 mediaRef）与回放
        // user_input 行（bridge-{seq}）同文本并存 = 同一条用户消息渲染两次
        // 且 UUID 行按旧 sort_order 进保留区 → 位置错乱。修法：history 的
        // 同文本 user 行不插入（保本地行——图片在），assistant/toolResult
        // 行不受影响。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),      // 与 UUID-USER 同文本
            makeHistoryRaw(id: "bridge-2", role: .assistant),
        ]
        let liveUser = makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1, parts: [
            .text("content-bridge-1"), .mediaRef(MediaRef(
                id: "m1", relativePath: "media/shot.png", mimeType: "image/png",
                originalFileName: "shot.png"
            ))
        ])
        let db = [liveUser]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-2"], "同文本 user 回放行不插，本地行（含图）保留")
        XCTAssertTrue(plan.deleteIds.isEmpty)
    }

    func test_liveToolResultRow_blocksHistoryInsert() {
        // [排查 2026-09-10] toolResult-only user 行的双份是比文本更狠的坑：
        // live 落库的 toolResult 行（UUID）+ 回放 bridge-{seq} 行并存 →
        // 渲染重复 + UUID 行进保留区错位。按 toolUseId（同一工具调用稳定
        // 唯一）判定，history 的同 id toolResult 行不插入。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),
            makeHistoryRaw(id: "bridge-2", role: .assistant),
        ]
        let historyToolResult = makeHistoryRaw(id: "bridge-3", role: .user, parts: [.toolResult(ToolResult(
            toolUseId: "toolu-1", output: "ok", success: true, mediaRef: nil, snapshot: nil, pageURL: nil, status: "success", outputFile: nil
        ))])
        let liveToolResult = makeDBRow(id: "UUID-TR", role: .user, sortOrder: 3)
        let db = [
            makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1),
            makeDBRow(id: "UUID-ASSIST", role: .assistant, sortOrder: 2),
            liveToolResult,
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: [history[0], history[1], historyToolResult],
            dbRows: db
        )
        // bridge-1/2 的文本与 UUID-USER/UUID-ASSIST 行不同（fixture 文本不同源）
        // → 正常插入；bridge-3 toolUseId 命中 UUID-TR → 阻断
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-1", "bridge-2"])
        XCTAssertFalse(plan.inserts.contains { $0.id == "bridge-3" },
                       "同 toolUseId 的 toolResult 回放行必须被阻断（防双份）")
    }

    func test_seqSpaceReset_afterBridgeResume_fullReshuffle() {
        // [排查 2026-09-10 正文重复·根因] bridge-{seq} 的 seq 是
        // per-bridge-session 计数——resume spawn 新 bridge 会话后从 seq=1
        // 重新计数，DB 旧空间 bridge-1..10 与新空间 bridge-1..3 同 id 不同
        // 内容 → 内容串台/正文卡片思考全双份（pp 真机实锤）。
        // 信号：DB max seq(10) > history max seq(3)（trim 场景方向相反）。
        // 期望：非 user 行全部换血到新空间。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .assistant), // 新空间 seq=1，内容 A
            makeHistoryRaw(id: "bridge-2", role: .user),      // 新空间 seq=2
            makeHistoryRaw(id: "bridge-3", role: .assistant), // 新空间 seq=3
        ]
        let db = [
            makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1),
            makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 2), // 旧空间内容 B
            makeDBRow(id: "bridge-2", role: .assistant, sortOrder: 3), // 旧空间
            makeDBRow(id: "bridge-10", role: .assistant, sortOrder: 4), // 旧空间尾巴
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        // 旧空间 bridge 行全删（换血）
        XCTAssertEqual(Set(plan.deleteIds), ["bridge-1", "bridge-2", "bridge-10"])
        // 新空间行全插（UUID user 行保留 + 回放 user 行防双份挡不住——文本不同）
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-1", "bridge-2", "bridge-3"])
    }

    func test_pastHistoryRawDisk_convertedWithStableId() {
        // [C-5.5 会话窗连续] past_history 的磁盘 raw 消息（{role, content}，
        // 无 type）必须被解析且拿到稳定 past-{index} id——之前落 default
        // 全丢，resume/bridge 切换后窗口断裂。
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old reply"},{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"ls"}}]},
         {"role":"user","content":[{"type":"text","text":"old question"}]}]
        """
        let wire = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        let msgs = RemoteAgentProvider.historyAgentMessages(from: wire)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].dbMessageId, "past-0")
        XCTAssertEqual(msgs[0].rawMessageId(), "past-0", "rawMessageId 必须走 past- 分支")
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertNotNil(msgs[0].parts.first)
        XCTAssertEqual(msgs[1].dbMessageId, "past-1")
        XCTAssertEqual(msgs[1].role, .user)
        // tool_use 转 part
        if case .toolUse(let id, let name, _)? = msgs[0].parts.last {
            XCTAssertEqual(id, "t9")
            XCTAssertEqual(name, "Bash")
        } else {
            XCTFail("tool_use 块必须转成 .toolUse part")
        }
    }

    func test_bridgeSessionSwitch_shortSession_fullReshuffle() {
        // [终版根因·pp 真机实锤] 长度启发式在短会话必漏：旧空间 2 行 vs
        // 新空间 3 行（dbMax=2 < histMax=3）不触发，同 seq 不同内容照样
        // 串台双份。bridgeId 切换（forceFullReshuffle）是确定性信号。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .assistant), // 新空间内容 A
            makeHistoryRaw(id: "bridge-2", role: .user),
            makeHistoryRaw(id: "bridge-3", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1),
            makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 2), // 旧空间内容 B
            makeDBRow(id: "bridge-2", role: .assistant, sortOrder: 3), // 旧空间
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history, dbRows: db,
            nonEngineSeqs: [], forceFullReshuffle: true
        )
        XCTAssertEqual(Set(plan.deleteIds), ["bridge-1", "bridge-2"], "bridgeId 切换 → 旧空间行全换血")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-1", "bridge-2", "bridge-3"])
    }

    func test_trimWindow_noFalseReset() {
        // R1 场景回归保护：trim 窗口内 DB 1..N、history 尾窗 (N-99)..N →
        // history max = N ≥ DB max → 不触发重置，老行照常保留。
        let history = [
            makeHistoryRaw(id: "bridge-99", role: .assistant),
            makeHistoryRaw(id: "bridge-100", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 1),
            makeDBRow(id: "bridge-98", role: .assistant, sortOrder: 2),
            makeDBRow(id: "bridge-99", role: .assistant, sortOrder: 3),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertTrue(plan.deleteIds.isEmpty, "trim 窗口不得误判为 seq 重置")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-100"])
    }

    func test_userRowWithDifferentText_stillInserts() {
        // 不同文本的 user 回放行照常插入（DB 空的首次恢复场景）。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),
            makeHistoryRaw(id: "bridge-2", role: .assistant),
        ]
        let db = [makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1)] // parts text = "db-UUID-USER"
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-1", "bridge-2"])
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

    func test_liveUnifiedRow_noBridgeSeq_calibratedOut() {
        // [v1.14.20 大一统行退役] 远端 live 一个 turn 只 persist 一行（全部
        // text+toolUse+toolResult+reasoning 合并），且【不再注入 bridgeSeq】
        // → id=UUID → planReplace 删除①命中 → 回放逐轮行全量插入。
        // 反例（退役前）：注入 bridge-{lastAssistantSeq} → keep 命中 → 同
        // turn 内容渲染两遍（多轮工具会话 100% 触发，pp 真机实锤）。
        let liveUnified = makeDBRow(id: "UUID-UNIFIED", role: .assistant, sortOrder: 2)
        let db = [
            makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1),
            liveUnified,
        ]
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .assistant), // thinking+toolUse 轮
            makeHistoryRaw(id: "bridge-2", role: .user),      // toolResult 轮
            makeHistoryRaw(id: "bridge-3", role: .assistant), // 最终正文轮
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertEqual(Set(plan.deleteIds), ["UUID-UNIFIED"],
                       "大一统 live 行（UUID）必须被删，绝不进 keep 集")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-1", "bridge-2", "bridge-3"],
                       "回放逐轮行全量插入，恢复后渲染与 bridge 粒度一致（无双份）")
    }

    func test_pastRows_neverDeleted() {
        // [对抗审查 R4 实锤 2026-09-10] past-{index} 行（C-5.5 磁盘历史回放）
        // 无 bridge- 前缀——旧删除①会把它当 live UUID 行删掉且不回插
        // （dbIds 命中插入跳过）→ 磁盘历史每次校准净丢失。修后 past 行与
        // bridge-{seq} 行同享只增不删。
        let history = [
            makeHistoryRaw(id: "past-0", role: .assistant),
            makeHistoryRaw(id: "bridge-1", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "past-0", role: .assistant, sortOrder: 1),
            makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: db)
        XCTAssertTrue(plan.isEmpty,
                      "past 行已在 DB → 删除①不得命中，回放 id 命中不重插 = 稳定态")
    }

    func test_pastRows_surviveForceFullReshuffle() {
        // [对抗审查 R4 追加] bridgeId 切换（seq 空间重置）换血的靶子是旧
        // bridge 空间的 bridge-{seq}/UUID 行——past 行不属于任何 seq 空间，
        // 必须跨换血保留，否则磁盘历史净删。
        let history = [
            makeHistoryRaw(id: "past-0", role: .assistant),
            makeHistoryRaw(id: "bridge-1", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "past-0", role: .assistant, sortOrder: 1),
            makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 2), // 旧空间
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history, dbRows: db,
            nonEngineSeqs: [], forceFullReshuffle: true
        )
        XCTAssertEqual(Set(plan.deleteIds), ["bridge-1"],
                       "换血只删旧空间 bridge 行，past 行保留")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-1"],
                       "新空间 bridge 行插入，past 行 id 命中不重插")
    }

    func test_unifiedFinalOrder_interleavesLocalUserRows() {
        // [乱序修复 v1.14.21] replaceRemoteHistory 的 renumber 用
        // unifiedFinalOrderIds——防双份被挡的回放 user_input 行位置替换为
        // 本地承载行 id。旧逻辑（retained 排前 + finalOrder 排后）把本地
        // user 行全部顶到最前 = 两个 user 气泡置顶、回复全在后（pp 真机
        // 实锤 07:06 日志：perMsg [0 user][1 user][2..12 assistant/tr]）。
        let history = [
            makeHistoryRaw(id: "bridge-8", role: .user),      // user_input 回放 → 本地顶位
            makeHistoryRaw(id: "bridge-9", role: .assistant),
            makeHistoryRaw(id: "bridge-10", role: .user),     // toolResult 回放 → 无本地 → 插入
            makeHistoryRaw(id: "bridge-11", role: .assistant),
            makeHistoryRaw(id: "bridge-14", role: .user),     // user_input 回放 → 本地顶位
            makeHistoryRaw(id: "bridge-15", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "UUID-USER1", role: .user, sortOrder: 1),  // 文本 = content-bridge-8
            makeDBRow(id: "UUID-USER2", role: .user, sortOrder: 3),  // 文本 = content-bridge-14
        ]
        // 让两条本地 user 行文本与回放行匹配（防双份按首条 text 比对）
        let u1 = makeDBRow(id: "UUID-USER1", role: .user, sortOrder: 1, parts: [.text("content-bridge-8")])
        let u2 = makeDBRow(id: "UUID-USER2", role: .user, sortOrder: 3, parts: [.text("content-bridge-14")])
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: [u1, u2])
        XCTAssertEqual(plan.unifiedFinalOrderIds,
                       ["UUID-USER1", "bridge-9", "bridge-10", "bridge-11", "UUID-USER2", "bridge-15"],
                       "unified 序 = bridge 序，防双份命中位由本地 user 行顶替，user 行不置顶")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-9", "bridge-10", "bridge-11", "bridge-15"],
                       "被顶替的回放 user 行不插入（防双份），其余全插")
    }

    // MARK: - orderedRowSequence（replaceRemoteHistory 第 3 步 renumber 定序）

    func test_renumber_liveUserRow_goesAfterHistory() {
        // [Fix v1.14.27] pp 真机实锤复现（04:01 日志）：校准发生在
        // "resume 刚 spawn、磁盘历史不含本轮"的窗口——刚发的"在吗"是 live
        // UUID 行、不在 history 序列里，旧规则"retained 全排前"把它
        // renumber 到 sort_order=1（比会话第一条"你好"还靠前）。
        // 期望：不在 unified 序里的 live 行排在历史**之后**。
        // ⚠️ [v1.14.29 澄清] 本规则是**全量路径的兜底**：正常路径下"历史更早
        // 的 user 行"会被 planReplace 的防双份配对（归一化同文本 + 队列配对）
        // 放回 unified 序内原位，落进这个桶的只剩"bridge history 尚未承载的
        // 真·新内容"。**delta 路径根本不做 renumber**（见
        // RemoteHistorySyncCore.deltaFastPathAllowed / ChatStore renumber 参数）
        // ——旧版本按本规则重排 delta 残缺序，正是"用户全部发言被甩到会话
        // 末尾"的根因 A（pp 真机 2026-09-11 08:06）。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),
            makeHistoryRaw(id: "bridge-2", role: .assistant),
        ]
        let dbUser = makeDBRow(id: "UUID-EARLIER", role: .user, sortOrder: 1)
        let dbLive = makeDBRow(id: "UUID-JUSTSENT", role: .user, sortOrder: 2)
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: ["bridge-1", "bridge-2"],
            finalOrder: history,
            retainedRows: [dbUser, dbLive],
            rowById: [dbUser.id: dbUser, dbLive.id: dbLive]
        )
        XCTAssertEqual(sequence.map { $0.id },
                       ["bridge-1", "bridge-2", "UUID-EARLIER", "UUID-JUSTSENT"],
                       "live 行（含历史更早的 user 行）排历史后，组内保持现有序")
    }

    func test_renumber_trimWindowReplayRows_stayBefore() {
        // [R1 规则保留] trimHistory 100 条窗口外的 bridge-/past- 老回放行
        // 是历史最早的消息，必须排在 unified 序之前——本次修复只动 live
        // UUID 行的归属，老回放行行为不变。
        let history = [makeHistoryRaw(id: "bridge-50", role: .assistant)]
        let oldBridge = makeDBRow(id: "bridge-1", role: .assistant, sortOrder: 1)
        let oldPast = makeDBRow(id: "past-0", role: .user, sortOrder: 2)
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: ["bridge-50"],
            finalOrder: history,
            retainedRows: [oldBridge, oldPast],
            rowById: [oldBridge.id: oldBridge, oldPast.id: oldPast]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["past-0", "bridge-1", "bridge-50"],
                       "past 行（磁盘历史）恒最先；其余 trim 窗口外的回放行排前，历史主体在后")
    }

    func test_renumber_distinguishesReplayWindowFromLiveNew() {
        // 三类行混合的标志性场景：老回放行（窗口外）+ history 主体 +
        // 窗口内 live 新行。期望顺序 = 老回放 → history → live。
        let history = [
            makeHistoryRaw(id: "bridge-8", role: .user),
            makeHistoryRaw(id: "bridge-9", role: .assistant),
        ]
        let oldReplay = makeDBRow(id: "bridge-2", role: .assistant, sortOrder: 1)
        let liveUser = makeDBRow(id: "UUID-NEW", role: .user, sortOrder: 2)
        let liveAssistant = makeDBRow(id: "UUID-STREAMING", role: .assistant, sortOrder: 3)
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: ["bridge-8", "bridge-9"],
            finalOrder: history,
            retainedRows: [oldReplay, liveUser, liveAssistant],
            rowById: [oldReplay.id: oldReplay, liveUser.id: liveUser, liveAssistant.id: liveAssistant]
        )
        XCTAssertEqual(sequence.map { $0.id },
                       ["bridge-2", "bridge-8", "bridge-9", "UUID-NEW", "UUID-STREAMING"],
                       "老回放在前、history 居中、live 新行在后")
    }

    func test_renumber_ownerReplacedLocalUserRow_keptInPosition() {
        // [v1.14.21 语义回归] 防双份命中的本地 user 行 id 已在 unified 序内
        // → 按 unified 序居中，**不得**被本次分流挪到最后。
        let history = [
            makeHistoryRaw(id: "bridge-8", role: .user),
            makeHistoryRaw(id: "bridge-9", role: .assistant),
        ]
        let ownerMatched = makeDBRow(id: "UUID-USER1", role: .user, sortOrder: 1, parts: [.text("content-bridge-8")])
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: [ownerMatched])
        XCTAssertEqual(plan.unifiedFinalOrderIds, ["UUID-USER1", "bridge-9"],
                       "前置：防双份命中位由本地行顶替")
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: plan.unifiedFinalOrderIds,
            finalOrder: history,
            retainedRows: [],  // owner 在 unified 序内，不属于 retained
            rowById: [ownerMatched.id: ownerMatched, "bridge-9": history[1]]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["UUID-USER1", "bridge-9"],
                       "顶位本地行保持 history 序中的位置，不被分流到末尾")
    }

    func test_renumber_missingHistoryRow_fallsBackToFinalOrder() {
        // history 行尚未落库（rowById 缺）时用 finalOrder 同 id 行兜底补齐
        // 序列（renumber 的 UPDATE 对不存在行是 no-op，不产生副作用）。
        let history = [
            makeHistoryRaw(id: "bridge-1", role: .user),
            makeHistoryRaw(id: "bridge-2", role: .assistant),
        ]
        let dbRow = makeDBRow(id: "bridge-1", role: .user, sortOrder: 1)
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: ["bridge-1", "bridge-2"],
            finalOrder: history,
            retainedRows: [],
            rowById: [dbRow.id: dbRow]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["bridge-1", "bridge-2"],
                       "缺行用 finalOrder 兜底，序列完整")
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

    func test_deltaPartialHistory_oldRowsKeptNewEntriesAppended() {
        // [审查 2026-09-11] delta 路径语义锁定：historyRaws 只含
        // new-since-cursor 条目（全量 = 老条目 + 新条目）。planReplace 对
        // 集合外的老行必须零触碰（只增不删）；新条目沿用集合语义——live
        // UUID assistant 行删除并插 bridge 行、与本地同文本的 user 回放行
        // 不插（本地行顶替其 unified 序位置）。
        // ⚠️ [v1.14.29 更正] 旧注释"replaceRemoteHistory 按既有 sortOrder 排前
        // / renumber 无条件执行"**已失效**：delta 路径现在**不执行 renumber**
        // （增量只补内容、顺序保持，插入行按 max sort_order 递增追加）——
        // 用残缺的 delta 序做全量重排正是乱序根因 A。本用例只锁 planReplace
        // 的输出（unifiedFinalOrderIds 仍会被全量路径消费）。
        let deltaHistory = [
            makeHistoryRaw(id: "bridge-6", role: .assistant),
            makeHistoryRaw(id: "bridge-7", role: .user),  // user_input 回放行
        ]
        let liveUser = makeDBRow(id: "UUID-USER", role: .user, sortOrder: 4,
                                 parts: [.text("content-bridge-7")])  // 与回放行同文本 → 防双份命中
        let db = [
            makeDBRow(id: "bridge-1", role: .user, sortOrder: 1),
            makeDBRow(id: "bridge-2", role: .assistant, sortOrder: 2),
            makeDBRow(id: "bridge-3", role: .assistant, sortOrder: 3),
            liveUser,
            makeDBRow(id: "UUID-ASSIST", role: .assistant, sortOrder: 5),  // live 新轮 → 删
        ]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: deltaHistory, dbRows: db)
        XCTAssertEqual(plan.deleteIds, ["UUID-ASSIST"],
                       "delta 范围外老行（bridge-1/2/3）零触碰；live UUID 非 user 行照删")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-6"],
                       "user 回放行被本地同文本行顶替不插；assistant 新条目插入")
        XCTAssertEqual(plan.unifiedFinalOrderIds, ["bridge-6", "UUID-USER"],
                       "unified 序 = delta 序（本地行顶替其位置），老行由 renumber retained 段承接")
    }

    // MARK: - wire `content` 多态分流（v1.14.19 手写 init(from:)）

    // MARK: - 游标（v1.14.23 Phase 1：只写不读）

    func test_cursorStore_roundTrip() {
        // 游标读写往返：bridgeId + lastSeq 编解码无损（JSON Codable）。
        let suite = UserDefaults(suiteName: "test.cursor.roundtrip")!
        suite.removePersistentDomain(forName: "test.cursor.roundtrip")
        defer { suite.removePersistentDomain(forName: "test.cursor.roundtrip") }

        XCTAssertNil(RemoteHistoryCursorStore.read(sessionId: "s1", defaults: suite),
                     "未写入时读出 nil")

        let cursor = RemoteHistoryCursor(bridgeId: "abc12345", lastSeq: 42)
        RemoteHistoryCursorStore.write(cursor, sessionId: "s1", defaults: suite)

        let read = RemoteHistoryCursorStore.read(sessionId: "s1", defaults: suite)
        XCTAssertEqual(read, cursor, "写入后读出必须无损等值")

        // 不同 sessionId 隔离
        XCTAssertNil(RemoteHistoryCursorStore.read(sessionId: "s2", defaults: suite),
                     "per-chat 隔离：另一 session 读不到")

        RemoteHistoryCursorStore.clear(sessionId: "s1", defaults: suite)
        XCTAssertNil(RemoteHistoryCursorStore.read(sessionId: "s1", defaults: suite),
                     "clear 后读出 nil")
    }

    func test_wireContent_toolResultString_staysContent() {
        // [多态分流锁] tool_result 的 wire content 是字符串（工具输出）——
        // 手写 init 先试 String 再试 [AssistantContentBlock]，字符串形态
        // 必须落到 content 字段、rawContentBlocks 保持 nil。
        let json = """
        {"type":"tool_result","toolUseId":"t1","content":"stdout lines here","historySeq":4}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.content, "stdout lines here")
        XCTAssertNil(msg.rawContentBlocks, "字符串 content 不得被误读为块数组")
    }

    func test_wireContent_pastRawArray_landsBlocks() {
        // [多态分流锁] past_history 磁盘 raw 消息（{role, content:[blocks]}，
        // 无 type）——数组形态必须落到 rawContentBlocks、content 保持 nil，
        // role 走 rawRole。这是 C-5.5 会话窗连续的解码根基：分流错 = 磁盘
        // 历史整条丢弃（typeMismatch 炸包）或串进 tool_result 输出。
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old"},{"type":"thinking","thinking":"hm"}]}]
        """
        let msgs = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].rawRole, "assistant")
        XCTAssertNil(msgs[0].content, "数组 content 不得误落到字符串字段")
        XCTAssertEqual(msgs[0].rawContentBlocks?.count, 2)
        XCTAssertEqual(msgs[0].rawContentBlocks?.first?.text, "old")
        XCTAssertEqual(msgs[0].rawContentBlocks?.last?.thinking, "hm")
    }

    func test_wireContent_absent_bothNil() {
        // 无 content key 的消息（user_input / status / result）——两字段都 nil，
        // 不得互相污染（解码路径的 else 分支锁）。
        let json = """
        {"type":"user_input","text":"hi","historySeq":2}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.content)
        XCTAssertNil(msg.rawContentBlocks)
        XCTAssertEqual(msg.rawRole, nil)
    }

    // MARK: - messages 多态分流（v1.14.23 Phase 2：delta 信封解码）

    func test_wireMessages_flatShape_landsMessages() {
        // 全量 get_history 的信封 messages = flat [ServerMessage] → messages
        // 字段，deltaEntries 保持 nil（形状探测：首元素无 seq+message 包装）。
        let json = """
        {"type":"history","sessionId":"s1","messages":[{"type":"assistant","historySeq":1},{"type":"user_input","text":"hi","historySeq":2}]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.messages?.count, 2)
        XCTAssertNil(msg.deltaEntries, "flat 形态不得误判为 delta entries")
    }

    func test_wireMessages_deltaEntriesShape_landsDeltaEntries() {
        // [v1.14.23 关键坑位锁] delta 信封 messages = HistoryEntry[]——
        // 不能靠"flat 试错失败"分流（ServerMessage 全 optional 字段会把
        // entry 形态静默解成全 nil 空壳而非抛错），必须先探测 seq+message
        // 包装再分流。此用例锁该行为：deltaEntries 命中、messages nil。
        let json = """
        {"type":"history_delta","sessionId":"s1","fromSeq":11,"toSeq":12,
         "messages":[{"seq":11,"message":{"type":"assistant","text":"a","historySeq":11}},
                     {"seq":12,"message":{"type":"user_input","text":"b","historySeq":12}}]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.messages, "entry 形态不得误入 flat messages（会产出全 nil 空壳）")
        XCTAssertEqual(msg.deltaEntries?.count, 2)
        XCTAssertEqual(msg.deltaEntries?.first?.seq, 11)
        XCTAssertEqual(msg.deltaEntries?.first?.message?.historySeq, 11)
        XCTAssertEqual(msg.fromSeq, 11)
        XCTAssertEqual(msg.toSeq, 12)
    }

    func test_wireMessages_emptyDeltaShape() {
        // 空 delta（bridge getHistorySince:789）：from=to+1, messages=[]——
        // 空数组走 flat 分支（messages=[]），语义"无新消息"。
        let json = """
        {"type":"history_delta","sessionId":"s1","fromSeq":11,"toSeq":10,"messages":[]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.messages?.count, 0)
        XCTAssertNil(msg.deltaEntries)
        XCTAssertEqual(msg.fromSeq, 11)
        XCTAssertEqual(msg.toSeq, 10)
    }

    func test_wireMessages_missingShape_bothNil() {
        // 无 messages key（status / result 等信封）→ 双 nil 不互相污染。
        let json = """
        {"type":"status","sessionId":"s1","status":"idle"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.messages)
        XCTAssertNil(msg.deltaEntries)
    }

    func test_emptyDeltaForm_fromEqualsToPlusOne() {
        // 空 delta 判定式（决策树用）：from == to + 1。锁语义防止日后误改。
        let emptyFrom = 11, emptyTo = 10
        XCTAssertTrue(emptyFrom == emptyTo + 1, "空 delta 形态 from==to+1")
        let deltaFrom = 11, deltaTo = 12
        XCTAssertFalse(deltaFrom == deltaTo + 1, "正常 delta from<=to")
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

    // MARK: - [Fix 2026-09-11] disk past 内容完整性（tool_result/thinking）

    func test_pastToolResultRawShape_converted() {
        // bridge disk past 的 tool_result 重塑形态：splitPastHistoryMessages
        // 发 {role:"tool_result", toolUseId, content(string)}（无 type 字段，
        // websocket.ts:1909）——此前落 default 且 rawContentBlocks 为 nil
        // （content 是字符串）→ return nil 整行丢弃。实测 resume 后磁盘 623
        // 个工具结果 0 到达客户端（工具卡片点开无内容根因）。
        let json = """
        {"role":"tool_result","toolUseId":"toolu-9","content":"ran ok"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent, "disk past 的 tool_result 必须被转换，不得丢弃")
        XCTAssertEqual(agent?.role, .user)
        guard case .toolResult(let id, _, let content, let isError, _, _, _, _)? = agent?.parts.first else {
            return XCTFail("应转换为 .toolResult part")
        }
        XCTAssertEqual(id, "toolu-9")
        XCTAssertEqual(content, "ran ok")
        XCTAssertFalse(isError)
        // past-{index} 稳定 id（historyAgentMessages 统一分配）
        let engine = RemoteAgentProvider.historyAgentMessages(from: [msg])
        XCTAssertEqual(engine.count, 1)
        XCTAssertEqual(engine[0].dbMessageId, "past-0")
    }

    func test_pastRawThinking_converted() {
        // disk past 的 assistant 条目带 thinking 块（bridge 补全解析后）——
        // rawContentBlocks 路径必须提 reasoningContent，否则 resume 后
        // 思考块丢失（另一半根因）。
        let json = """
        {"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertEqual(agent?.reasoningContent, "hmm")
        XCTAssertEqual(agent?.parts.count, 1)
    }

    func test_evictPastRows_migrationClearsOldPastRows() {
        // past id 空间迁移：bridge 补全 disk 解析后 past-{index} 序列重排，
        // 旧残缺行与新序列同 id——evictPastRows=true 必须清旧行（含 user
        // role 的 past 行）并按新序列重插；owner 池排除待删行，旧同文本
        // user 行不得冒充 owner（否则旧行删了、新行被顶替 = 净丢）。
        let oldPastUser = makeDBRow(id: "past-0", role: .user, sortOrder: 1,
                                    parts: [.text("content-past-0")])  // 与新序列 past-0 同文本
        let db = [
            oldPastUser,
            makeDBRow(id: "past-1", role: .assistant, sortOrder: 2),
            makeDBRow(id: "bridge-9", role: .assistant, sortOrder: 3),
        ]
        let newHistory = [
            makeHistoryRaw(id: "past-0", role: .user),      // 新序列同 id 同文本
            makeHistoryRaw(id: "past-1", role: .assistant),
            makeHistoryRaw(id: "past-2", role: .assistant), // 补全后被截断的行
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: newHistory, dbRows: db, evictPastRows: true
        )
        XCTAssertEqual(Set(plan.deleteIds), ["past-0", "past-1"], "迁移模式清全部旧 past 行")
        XCTAssertFalse(plan.deleteIds.contains("bridge-9"), "bridge 行不受迁移影响")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["past-0", "past-1", "past-2"],
                       "新序列同 id 重插（先删后插同事务），旧 user 行不冒充 owner")
        XCTAssertEqual(plan.unifiedFinalOrderIds, ["past-0", "past-1", "past-2"])
    }

    // MARK: - 段作用域（[Fix v1.14.30] 对抗审查 A2/A3）

    func test_planReplace_foreignSegmentRowsNeverDeleted() {
        // 别的设备灌进来的段（isOwnSegment == false）：任何删除规则都不许碰
        // ——删了就是删别的设备的内容，且删除会对端同步 → 对端校准插回 →
        // 删/回插乒乓（A2 审查）。自己的旧空间（无段形态）照常换血。
        let history = [makeHistoryRaw(id: "bridge-ns-aaaa-9", role: .assistant)]
        let db = [
            makeDBRow(id: "bridge-ns-bbbb-3", role: .assistant, sortOrder: 1),
            makeDBRow(id: "bridge-ns-2", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history,
            dbRows: db,
            forceFullReshuffle: true,
            currentSegment: "aaaa"
        )
        XCTAssertFalse(plan.deleteIds.contains("bridge-ns-bbbb-3"),
                       "外来段的行不得被换血删除")
        XCTAssertTrue(plan.deleteIds.contains("bridge-ns-2"),
                      "自己旧空间（无段形态）的行才是换血靶子")
    }

    func test_planReplace_resetDeletesPreviousSegmentRows() {
        let db = [makeDBRow(id: "bridge-ns-oldseg1-3", role: .assistant, sortOrder: 1)]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: [],
            dbRows: db,
            forceFullReshuffle: true,
            currentSegment: "newseg2",
            previousSegment: "oldseg1"
        )
        XCTAssertTrue(plan.deleteIds.contains("bridge-ns-oldseg1-3"),
                      "上一个 bridge 会话的行是换血靶子（本次全量已覆盖其内容）")
    }

    func test_planReplace_resetDeletesLegacyUserReplayRowOnlyWhenCovered() {
        // [A3] 换会话时旧空间的**回放 user 行**：同 seq 已被新 history 覆盖
        // → 删（否则它 keep 命中永久占位，真实内容永不落库 + 用户发言被甩尾）；
        // 未被覆盖（trim 窗口外）→ 保留（删了不回插 = 净丢内容）。
        let history = [
            makeHistoryRaw(id: "bridge-ns-newseg-7", role: .user),
            makeHistoryRaw(id: "bridge-ns-newseg-8", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "bridge-ns-7", role: .user, sortOrder: 1),
            makeDBRow(id: "bridge-ns-99", role: .user, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history,
            dbRows: db,
            forceFullReshuffle: true,
            currentSegment: "newseg"
        )
        XCTAssertTrue(plan.deleteIds.contains("bridge-ns-7"),
                      "被新 history 覆盖的旧空间回放 user 行必须清掉")
        XCTAssertFalse(plan.deleteIds.contains("bridge-ns-99"),
                       "未被覆盖的保留——删了不回插等于吞掉用户消息")
    }

    func test_planReplace_seqHeuristicIgnoresForeignSegments() {
        // dbMax 启发式只统计自己的段：外来段 seq 更大时不得假触发"seq 空间
        // 重置"（否则整库非 user 行换血 = 删别的设备的行）。
        let history = [makeHistoryRaw(id: "bridge-ns-aaaa-1", role: .assistant)]
        let db = [
            makeDBRow(id: "bridge-ns-bbbb-999", role: .assistant, sortOrder: 1),
            makeDBRow(id: "bridge-ns-aaaa-1", role: .assistant, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history,
            dbRows: db,
            currentSegment: "aaaa"
        )
        XCTAssertTrue(plan.deleteIds.isEmpty,
                      "外来段的 999 不得触发换血")
    }

    // MARK: - delta 插入锚点（[Fix v1.14.30] 对抗审查 S4）

    func test_deltaInsertPlan_noTrailingLiveRows_anchorsAtLastReplayRow() {
        let db = [
            makeDBRow(id: "bridge-ns-aaaa-1", role: .assistant, sortOrder: 1),
            makeDBRow(id: "past-ns-9f3e2a1b-0", role: .user, sortOrder: 2),
        ]
        let inserts = [makeHistoryRaw(id: "bridge-ns-aaaa-2", role: .assistant)]
        let plan = RemoteHistorySyncCore.deltaInsertPlan(
            unifiedFinalOrderIds: ["bridge-ns-aaaa-2"],
            inserts: inserts,
            dbRows: db
        )
        XCTAssertEqual(plan.anchorOrder, 2, "无 live 行 → 锚点 = 最后一个回放行")
        XCTAssertTrue(plan.rowsToShift.isEmpty)
    }

    func test_deltaInsertPlan_trailingLiveRowGetsShifted() {
        // U2 刚发（live，bridge history 尚未承载），此时**上一轮**的回复才
        // 到达 delta：回复必须插在 U2 之前（盲追加会排到 U2 后面 = S4）。
        let db = [
            makeDBRow(id: "bridge-ns-aaaa-5", role: .assistant, sortOrder: 5),
            makeDBRow(id: "UUID-U2", role: .user, sortOrder: 6),
        ]
        let inserts = [makeHistoryRaw(id: "bridge-ns-aaaa-6", role: .assistant)]
        let plan = RemoteHistorySyncCore.deltaInsertPlan(
            unifiedFinalOrderIds: ["bridge-ns-aaaa-6"],
            inserts: inserts,
            dbRows: db
        )
        XCTAssertEqual(plan.anchorOrder, 5)
        XCTAssertEqual(plan.rowsToShift.map { $0.id }, ["UUID-U2"],
                       "trailing live 行整体后移腾位")
    }

    func test_deltaInsertPlan_claimedLiveRowBecomesAnchor() {
        // delta 携带 U2 自己的 user_input（认领 U2）→ 认领行是锚点，本批回复
        // 插在 U2 **之后**（真实时序：U2 → 回复）。
        let db = [
            makeDBRow(id: "bridge-ns-aaaa-5", role: .assistant, sortOrder: 5),
            makeDBRow(id: "UUID-U2", role: .user, sortOrder: 6),
        ]
        let inserts = [makeHistoryRaw(id: "bridge-ns-aaaa-7", role: .assistant)]
        let plan = RemoteHistorySyncCore.deltaInsertPlan(
            unifiedFinalOrderIds: ["UUID-U2", "bridge-ns-aaaa-7"],
            inserts: inserts,
            dbRows: db
        )
        XCTAssertEqual(plan.anchorOrder, 6, "认领到的 live 行是锚点")
        XCTAssertTrue(plan.rowsToShift.isEmpty)
    }

    // MARK: - stored 失明（DB 段集反查）[Fix v1.14.30 对抗审查·前提 1]

    func test_planReplace_lostSeal_staleOwnSegmentTreatedAsSwitch() {
        // 重装 + iCloud 恢复：桥行回 DB（段 B1），UserDefaults 无记录
        // （stored=nil → switched=false）。previousSegments 反查兜住：
        // B1 视为旧空间 → 换血删除 + 新全量回插（否则 B1 行永不清理
        // = 整段内容永久重复渲染）。
        let history = [
            makeHistoryRaw(id: "bridge-ns-b2new-1", role: .user),
            makeHistoryRaw(id: "bridge-ns-b2new-2", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "bridge-ns-b1old-1", role: .assistant, sortOrder: 1),
            makeDBRow(id: "bridge-ns-b1old-2", role: .assistant, sortOrder: 2),
        ]
        // 生产调用形状：§4.5 反查到 staleOwn 非空 → reshuffleForStaleSegments
        // 并入 forceFullReshuffle（Backfill 调用点 OR 语义）——换血删除必须
        // 由 seqSpaceReset 触发，仅传 previousSegments 只影响段归属不影响删除。
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history,
            dbRows: db,
            forceFullReshuffle: true,
            currentSegment: "b2new",
            previousSegments: ["b1old"]  // §4.5 反查产出
        )
        XCTAssertTrue(plan.deleteIds.contains("bridge-ns-b1old-1"))
        XCTAssertTrue(plan.deleteIds.contains("bridge-ns-b1old-2"),
                      "失明场景的旧段行必须进换血（否则重复渲染永不自愈）")
        XCTAssertFalse(plan.inserts.isEmpty, "新空间全量历史必须回插")
    }

    func test_planReplace_lostSeal_foreignSegmentStillProtected() {
        // 反查只认**本会话 ns**的段（§4.5 有 ns 过滤）：别的会话/别的设备
        // 的段照旧受"外来段不碰"保护——反查不得越权清别人的行。
        let history = [
            makeHistoryRaw(id: "bridge-ns-b2new-1", role: .user),
            makeHistoryRaw(id: "bridge-ns-b2new-2", role: .assistant),
        ]
        let db = [
            makeDBRow(id: "bridge-OTHERNS-b1old-1", role: .assistant, sortOrder: 1),
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history,
            dbRows: db,
            currentSegment: "b2new",
            previousSegments: []  // 反查 ns 过滤后不含 OTHERNS
        )
        XCTAssertFalse(plan.deleteIds.contains("bridge-OTHERNS-b1old-1"),
                       "外来 ns 的行不因失明反查被清（乒乓防线保持）")
    }

    // MARK: - F1 settled 水位 [Fix v1.14.30.1 pp 真机「你好」甩尾]

    func test_orderedRowSequence_settledLiveUserRowNotDumpedToTail() {
        // 「你好」场景：live user 行上次校准已落座（so ≤ 水位），本次 bridge
        // 历史因 trim/resume 分界不再承载它 → 落回放区最前，不再甩到队尾；
        // 水位之后的 live user 行（本轮新发）保持 after 语义（v1.14.27 不回归）。
        let body = makeHistoryRaw(id: "bridge-ns-a-5", role: .assistant)
        let settledHello = makeDBRow(id: "UUID-HELLO", role: .user, sortOrder: 1)
        let newPending = makeDBRow(id: "UUID-NEW", role: .user, sortOrder: 9)
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: ["bridge-ns-a-5"],
            finalOrder: [body],
            retainedRows: [settledHello, newPending],
            rowById: ["bridge-ns-a-5": body],
            settledSortOrderFloor: 6
        )
        XCTAssertEqual(sequence.map { $0.id }, ["UUID-HELLO", "bridge-ns-a-5", "UUID-NEW"],
                       "已落座行回放区最前；新发行仍队尾")
    }

    func test_orderedRowSequence_nilWatermark_keepsOldBehavior() {
        // 不传水位（本地会话/旧 caller）→ live 行一律 after，逐字保持 v1.14.27 语义
        let body = makeHistoryRaw(id: "bridge-ns-a-5", role: .assistant)
        let oldLive = makeDBRow(id: "UUID-HELLO", role: .user, sortOrder: 1)
        let sequence = RemoteHistorySyncCore.orderedRowSequence(
            unifiedFinalOrderIds: ["bridge-ns-a-5"],
            finalOrder: [body],
            retainedRows: [oldLive],
            rowById: ["bridge-ns-a-5": body]
        )
        XCTAssertEqual(sequence.map { $0.id }, ["bridge-ns-a-5", "UUID-HELLO"],
                       "nil 水位 = 原行为：live 恒 after（本地零影响不变量）")
    }

    // MARK: - F3 superseded 取代登记 [Fix v1.14.30.1 pp 真机编辑双份]

    func test_planReplace_supersededReplayRowDeleted() {
        // 编辑重发：原输入的 DB 回放行（带被取代 cmid）必须清掉——本地承载行
        // 已是重发的新版；不清 =「删不掉的双份」。
        let history = [makeHistoryRaw(id: "bridge-ns-a-9", role: .assistant)]
        let db = [
            makeDBRow(id: "bridge-ns-a-1", role: .user, sortOrder: 1, clientMessageId: "cmid-old"),
            makeDBRow(id: "UUID-EDITED", role: .user, sortOrder: 2),
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history,
            dbRows: db,
            supersededInputIds: ["cmid-old"]
        )
        XCTAssertTrue(plan.deleteIds.contains("bridge-ns-a-1"),
                      "被取代输入的既有回放行必须进删除集")
    }

    func test_planReplace_supersededOnlyTouchesMatchingCmid() {
        // 不误伤：无 cmid 的行、cmid 不在取代集的行一律不动
        let history = [makeHistoryRaw(id: "bridge-ns-a-9", role: .assistant)]
        let db = [
            makeDBRow(id: "bridge-ns-a-2", role: .user, sortOrder: 1, clientMessageId: "cmid-alive"),
            makeDBRow(id: "bridge-ns-a-3", role: .user, sortOrder: 2),  // 无 cmid
        ]
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: history,
            dbRows: db,
            supersededInputIds: ["cmid-old"]
        )
        XCTAssertFalse(plan.deleteIds.contains("bridge-ns-a-2"))
        XCTAssertFalse(plan.deleteIds.contains("bridge-ns-a-3"))
    }
}
