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
        var liveUser = makeDBRow(id: "UUID-USER", role: .user, sortOrder: 1)
        liveUser.parts = [.text("content-bridge-1"), .mediaRef(MediaRef(
            id: "m1", relativePath: "media/shot.png", mimeType: "image/png",
            originalFileName: "shot.png"
        ))]
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
        var historyToolResult = makeHistoryRaw(id: "bridge-3", role: .user)
        historyToolResult.parts = [.toolResult(ToolResult(
            toolUseId: "toolu-1", output: "ok", success: true, mediaRef: nil, snapshot: nil, pageURL: nil, status: "success", outputFile: nil
        ))]
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
        var u1 = db[0]; u1.parts = [.text("content-bridge-8")]
        var u2 = db[1]; u2.parts = [.text("content-bridge-14")]
        let plan = RemoteHistorySyncCore.planReplace(historyRaws: history, dbRows: [u1, u2])
        XCTAssertEqual(plan.unifiedFinalOrderIds,
                       ["UUID-USER1", "bridge-9", "bridge-10", "bridge-11", "UUID-USER2", "bridge-15"],
                       "unified 序 = bridge 序，防双份命中位由本地 user 行顶替，user 行不置顶")
        XCTAssertEqual(plan.inserts.map { $0.id }, ["bridge-9", "bridge-10", "bridge-11", "bridge-15"],
                       "被顶替的回放 user 行不插入（防双份），其余全插")
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

    // MARK: - wire `content` 多态分流（v1.14.19 手写 init(from:)）

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
