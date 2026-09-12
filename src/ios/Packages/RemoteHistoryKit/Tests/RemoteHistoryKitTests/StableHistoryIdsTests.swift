import XCTest
@testable import RemoteHistoryKit

/// [stable history ids · C3/C4] 稳定身份路径的行为锁定。
///
/// 背景（本批要根治的病）：桥的 history 窗口 FIFO 100 条，游标掉出水位后
/// `get_history_delta` 回 `history_snapshot{reason:compacted}` → iOS 走全量
/// fallback → `planReplace` + `replaceRemoteHistory` 做**全局 renumber 1..M**
/// → 本地保留的窗口外旧消息被卷入重排、散开 = pp 真机反复复现的"远端历史
/// 乱序"。根治思路：桥注入稳定 `messageUuid`，行身份 = `bm-{uuid}`，客户端
/// 只做**幂等 upsert + 锚点落位**，绝不重排旧行。
///
/// 本文件锁死三组不变量：
/// 1. `ReplayRowId.stable` / `parseStableUuid` / `isReplayRow` 的第四代形态；
/// 2. `planStableReplace` 的幂等性与 deleteIds 恒空（无撤回语义）；
/// 3. `stableSortOrders` / `stableSegmentRenumber` 的"只给新行找位置、
///    不碰段外行"契约。
final class StableHistoryIdsTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRaw(
        id: String,
        role: MessageRole = .assistant,
        text: String = "t",
        sortOrder: Int = 0
    ) -> RawMessage {
        RawMessage(
            id: id, sessionId: "test-session", role: role,
            parts: [.text(text)],
            createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: nil
        )
    }

    private func bm(_ uuid: String) -> String { "bm-\(uuid)" }

    // MARK: - 1. 第四代 id 形态（ReplayRowId）

    /// `bm-` 前缀是回放行的判别依据；`isReplayRow` 必须放行它——否则**回滚**
    /// （关 flag / 降级桥）后旧路径会把 stable 行误判为 live UUID 行并删掉，
    /// 历史被吞。这是回滚安全的关键闸门。
    func test_stable_isReplayRow_acceptsBmPrefix() {
        XCTAssertTrue(ReplayRowId.isReplayRow(bm("3f9a-1b")))
        XCTAssertTrue(ReplayRowId.isReplayRow("bridge-abc-8"),
                      "老形态不受影响")
        XCTAssertTrue(ReplayRowId.isReplayRow("past-abc-def-3"))
        XCTAssertFalse(ReplayRowId.isReplayRow("F5FD19FD-D052-47FE-989D-078E0EC7EB1E"),
                       "本地 live UUID 行不得被判成回放行")
    }

    func test_stable_roundTrip() {
        let id = ReplayRowId.stable(messageUuid: "3f9a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8")
        XCTAssertEqual(id, "bm-3f9a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8")
        XCTAssertEqual(
            ReplayRowId.parseStableUuid(id!),
            "3f9a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8"
        )
    }

    func test_stable_nilOrEmptyReturnsNil() {
        XCTAssertNil(ReplayRowId.stable(messageUuid: nil),
                     "旧桥不带 uuid → 返回 nil，调用方回退 bridge-/past- 形态")
        XCTAssertNil(ReplayRowId.stable(messageUuid: ""))
    }

    /// 上游传了脏值（含 `/`、空格、控制字符）时必须拒绝，而不是拼成非法主键。
    /// `messages.id` 是全局 PRIMARY KEY，静默损坏的代价是整行内容不可寻址。
    func test_stable_rejectsUnsafeCharacters() {
        XCTAssertNil(ReplayRowId.stable(messageUuid: "a/b"))
        XCTAssertNil(ReplayRowId.stable(messageUuid: "a b"))
        XCTAssertNil(ReplayRowId.stable(messageUuid: "a\nb"))
        XCTAssertNil(ReplayRowId.stable(messageUuid: "../etc/passwd"))
        // 合法字符（UUID 形态 + 桥的 transcript uuid）必须放行
        XCTAssertNotNil(ReplayRowId.stable(messageUuid: "3f9a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8"))
        XCTAssertNotNil(ReplayRowId.stable(messageUuid: "ABC_def-123"))
    }

    func test_parseStableUuid_onlyForStableShape() {
        XCTAssertNil(ReplayRowId.parseStableUuid("bridge-abc-8"))
        XCTAssertNil(ReplayRowId.parseStableUuid("past-abc-def-3"))
        XCTAssertNil(ReplayRowId.parseStableUuid("F5FD19FD-D052-47FE-989D-078E0EC7EB1E"))
        XCTAssertNil(ReplayRowId.parseStableUuid("bm-"), "空前缀尾 = nil")
        XCTAssertEqual(ReplayRowId.parseStableUuid(bm("x")), "x")
    }

    // MARK: - 2. planStableReplace

    /// 幂等：已在库的行重复到达 = keep，零插入、零删除。这是"稳定路径每次同步
    /// 都跑也不会抖动"的根基。
    func test_plan_idempotentWhenAllPresent() {
        let rows = [makeRaw(id: bm("a"), sortOrder: 1000), makeRaw(id: bm("b"), sortOrder: 2000)]
        let plan = RemoteHistorySyncCore.planStableReplace(stableRaws: rows, dbRows: rows)
        XCTAssertTrue(plan.inserts.isEmpty)
        XCTAssertTrue(plan.deleteIds.isEmpty)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.keptCount, 2)
    }

    func test_plan_insertsOnlyNewRows() {
        let db = [makeRaw(id: bm("a"), sortOrder: 1000)]
        let raws = [makeRaw(id: bm("a")), makeRaw(id: bm("b")), makeRaw(id: bm("c"))]
        let plan = RemoteHistorySyncCore.planStableReplace(stableRaws: raws, dbRows: db)
        XCTAssertEqual(plan.inserts.map { $0.id }, [bm("b"), bm("c")])
        XCTAssertEqual(plan.deleteIds, [], "stable 路径无撤回语义 → 恒不删")
    }

    /// 锚点推导：新行的 `afterRowId` 必须是**前一条**已落位行（已存在或本次
    /// 已插入），否则落位无从谈起。
    func test_plan_anchorChain() {
        let db = [makeRaw(id: bm("a"), sortOrder: 1000)]
        let raws = [makeRaw(id: bm("a")), makeRaw(id: bm("b")), makeRaw(id: bm("c"))]
        let plan = RemoteHistorySyncCore.planStableReplace(stableRaws: raws, dbRows: db)
        XCTAssertEqual(plan.placements.count, 2)
        XCTAssertEqual(plan.placements[0].rowId, bm("b"))
        XCTAssertEqual(plan.placements[0].afterRowId, bm("a"),
                       "b 排在已存在的 a 之后")
        XCTAssertEqual(plan.placements[1].rowId, bm("c"))
        XCTAssertEqual(plan.placements[1].afterRowId, bm("b"),
                       "c 排在本批已插入的 b 之后（链式推进）")
    }

    func test_plan_pureAppendDetection() {
        // DB 无 stable 段 → 全量首次落地 = 纯追加
        let plan1 = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a")), makeRaw(id: bm("b"))],
            dbRows: []
        )
        XCTAssertTrue(plan1.isPureAppend)

        // 新行全部接在已有 stable 行之后 → 纯追加
        let db = [makeRaw(id: bm("a"), sortOrder: 1000)]
        let plan2 = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a")), makeRaw(id: bm("b"))],
            dbRows: db
        )
        XCTAssertTrue(plan2.isPureAppend)

        // 无新行 → 不是追加（没有"增长"这回事）
        let plan3 = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a"))],
            dbRows: db
        )
        XCTAssertFalse(plan3.isPureAppend)
    }

    /// **本批最重要的契约**：plan 不产生任何 deleteIds——旧行不可能因为一次
    /// 校准而消失。旧路径的"删了旧的、插不进新的"净丢失在稳定路径上结构性
    /// 不存在。
    func test_plan_neverDeletesEvenWhenSnapshotShrinks() {
        let db = [makeRaw(id: bm("a"), sortOrder: 1000), makeRaw(id: bm("b"), sortOrder: 2000)]
        // 快照只含 a（b 掉出窗口）→ 绝不能因此删 b
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a"))],
            dbRows: db
        )
        XCTAssertEqual(plan.deleteIds, [],
                       "窗口收缩不得触发删除——本地保留的窗口外旧消息是历史的一部分")
        XCTAssertTrue(plan.inserts.isEmpty)
    }

    // MARK: - 3. stableSortOrders

    func test_sortOrders_appendAfterAnchor() {
        let db = [makeRaw(id: bm("a"), sortOrder: 1000)]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a")), makeRaw(id: bm("b"))],
            dbRows: db
        )
        let orders = RemoteHistorySyncCore.stableSortOrders(plan: plan, dbRows: db)
        XCTAssertEqual(orders[bm("b")], 2000, "锚点 1000 + step 1000")
    }

    func test_sortOrders_cascadesWithinBatch() {
        let db = [makeRaw(id: bm("a"), sortOrder: 1000)]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a")), makeRaw(id: bm("b")), makeRaw(id: bm("c"))],
            dbRows: db
        )
        let orders = RemoteHistorySyncCore.stableSortOrders(plan: plan, dbRows: db)
        XCTAssertEqual(orders[bm("b")], 2000)
        XCTAssertEqual(orders[bm("c")], 3000, "同批内链式递增")
    }

    /// 无锚点（DB 无 stable 段）→ 从 DB 最大序号之后起追加。
    func test_sortOrders_withoutAnchorStartsAfterDbMax() {
        let db = [makeRaw(id: "live-uuid", role: .user, sortOrder: 700)]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a"))],
            dbRows: db
        )
        let orders = RemoteHistorySyncCore.stableSortOrders(plan: plan, dbRows: db)
        XCTAssertEqual(orders[bm("a")], 1700, "700 + 1000")
    }

    /// `stableSortOrders` 只管新行——已有行的序号绝不能出现在返回表里。
    func test_sortOrders_neverTouchesExistingRows() {
        let db = [makeRaw(id: bm("a"), sortOrder: 1000), makeRaw(id: bm("b"), sortOrder: 2000)]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a")), makeRaw(id: bm("b")), makeRaw(id: bm("c"))],
            dbRows: db
        )
        let orders = RemoteHistorySyncCore.stableSortOrders(plan: plan, dbRows: db)
        XCTAssertNil(orders[bm("a")])
        XCTAssertNil(orders[bm("b")])
        XCTAssertNotNil(orders[bm("c")])
    }

    // MARK: - 4. stableSegmentRenumber

    /// 顺序已严格递增 → 零写入（幂等校准"不该动的绝不动"）。
    func test_segmentRenumber_noopWhenAlreadyAscending() {
        let db = [
            makeRaw(id: bm("a"), sortOrder: 1000),
            makeRaw(id: bm("b"), sortOrder: 2000),
            makeRaw(id: bm("c"), sortOrder: 3000),
        ]
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("b"), bm("c")],
            newRowOrders: [:],
            dbRows: db
        )
        XCTAssertTrue(result.isEmpty, "无需整形时返回空表 → 零 UPDATE")
    }

    /// **中间落位**：a(1000) 与 c(3000) 之间补 b → b 必须落在 (1000, 3000) 内，
    /// 而不是像 `stableSortOrders` 初值那样给 2000 后再撞 c。
    func test_segmentRenumber_placesNewRowBetweenNeighbours() {
        let db = [
            makeRaw(id: bm("a"), sortOrder: 1000),
            makeRaw(id: bm("c"), sortOrder: 3000),
        ]
        // 权威顺序 a → b → c；b 是新行
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("b"), bm("c")],
            newRowOrders: [bm("b"): 2000],
            dbRows: db
        )
        let aOrder = result[bm("a")] ?? 1000
        let bOrder = result[bm("b")]!
        let cOrder = result[bm("c")] ?? 3000
        XCTAssertTrue(aOrder < bOrder, "a 必须在 b 之前（a=\(aOrder), b=\(bOrder)）")
        XCTAssertTrue(bOrder < cOrder, "b 必须在 c 之前（b=\(bOrder), c=\(cOrder)）")
        XCTAssertEqual(result[bm("b")], 2000, "三行等距：1000/2000/3000")
    }

    /// 段外行（live UUID / 老 bridge- / past-）**一个都不许出现在返回表里**。
    /// 这是与旧路径 renumber 的分水岭——旧路径把它们卷进 1..M 重排 = 乱序病根。
    func test_segmentRenumber_neverEmitsNonStableRows() {
        let db = [
            makeRaw(id: "live-uuid", role: .user, sortOrder: 500),
            makeRaw(id: bm("a"), sortOrder: 1000),
            makeRaw(id: "bridge-abc-9", sortOrder: 2000),
            makeRaw(id: "past-abc-def-3", sortOrder: 2500),
            makeRaw(id: bm("c"), sortOrder: 3000),
        ]
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("b"), bm("c")],
            newRowOrders: [bm("b"): 2000],
            dbRows: db
        )
        XCTAssertNil(result["live-uuid"])
        XCTAssertNil(result["bridge-abc-9"])
        XCTAssertNil(result["past-abc-def-3"])
        XCTAssertNotNil(result[bm("b")])
    }

    /// [B-3/B-4 修订] 整形采用**固定步长**，因此段内行数超出原区间时不再压缩
    /// step（旧实现的越界根因），只要后面没有段外行，整段可以正常展开。
    func test_segmentRenumber_fixedStepExpandsWhenNoBlocker() {
        let db = [
            makeRaw(id: bm("a"), sortOrder: 100),
            makeRaw(id: bm("b"), sortOrder: 200),
            makeRaw(id: bm("c"), sortOrder: 300),
        ]
        // 顺序被打乱（b 与 c 互换）→ 触发整形
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("c"), bm("b")],
            newRowOrders: [:],
            dbRows: db
        )
        XCTAssertFalse(result.isEmpty, "乱序必须触发整形")
        // 固定步长 1000，base = lo = 100：a=100（**未变 → 不写**）、c=1100、b=2100。
        // "不该动的绝不动"：a 已经在正确位置，就不产生 UPDATE。
        XCTAssertNil(result[bm("a")], "a 序号未变 → 必须零写入")
        let a = result[bm("a")] ?? 100
        let c = result[bm("c")]!
        let b = result[bm("b")]!
        XCTAssertTrue(a < c && c < b, "必须严格遵循权威顺序 a → c → b")
    }

    /// [B-3] 段内行数超出可用区间、且后面紧跟段外行时，**不得越过段外行**：
    /// 整段向下平移腾位，而不是压缩步长（压缩会破坏幂等并冲出区间）。
    func test_segmentRenumber_shiftsDownInsteadOfOverrunning() {
        let db = [
            makeRaw(id: bm("a"), sortOrder: 100),
            makeRaw(id: bm("b"), sortOrder: 200),
            makeRaw(id: bm("c"), sortOrder: 300),
            // 紧随其后的段外行：stable 段绝不能越过 400。
            makeRaw(id: "live-uuid", role: .user, sortOrder: 400),
        ]
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("b"), bm("c")],
            newRowOrders: [:],
            dbRows: db
        )
        // 段内三行固定步长需要 2000 的跨度，而段外行在 400 —— 装不下 →
        // 整段向下平移。三行必须都排在 400 之前且互不相同。
        let all = db.filter { $0.id.hasPrefix("bm-") }
            .map { result[$0.id] ?? $0.sortOrder }
        XCTAssertEqual(Set(all).count, all.count, "平移后不得撞号：\(all)")
        XCTAssertLessThan(all.max()!, 400, "整形结果必须严格小于段外行序号")
        XCTAssertGreaterThanOrEqual(all.min()!, 0, "平移不得产生负序号")
        XCTAssertNil(result["live-uuid"], "段外行一个都不许被写")
        // 平移后 a 的序号确实变了 → 必须写。
        XCTAssertNotNil(result[bm("a")], "整段平移必须重写每一行")
    }

    /// 顺序已对时零写入；**再次**调用也零写入（幂等），因为 step 不依赖跨度。
    func test_segmentRenumber_isIdempotentAcrossRepeatedCalls() {
        let db = [
            makeRaw(id: bm("a"), sortOrder: 500),
            makeRaw(id: bm("b"), sortOrder: 700),
            makeRaw(id: bm("c"), sortOrder: 900),
        ]
        let first = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("c"), bm("b")],
            newRowOrders: [:],
            dbRows: db
        )
        XCTAssertFalse(first.isEmpty)

        // 把第一次的结果落库，再来一次 —— 必须为空（不产生任何 UPDATE）。
        let settled = db.map { row -> RawMessage in
            guard let order = first[row.id] else { return row }
            return makeRaw(id: row.id, role: row.role, sortOrder: order)
        }
        let second = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("c"), bm("b")],
            newRowOrders: [:],
            dbRows: settled
        )
        XCTAssertTrue(second.isEmpty, "同输入重复整形必须零写入（幂等），实际 \(second)")
    }

    /// [B-6] 段内残留的旧形态行也要参与占位，否则 stable 序号会与它们撞号。
    func test_segmentRenumber_countsLegacyRowsAsPlaceholders() {
        let legacy = "bridge-ns-seg-2"
        let db = [
            makeRaw(id: bm("a"), sortOrder: 1000),
            makeRaw(id: legacy, sortOrder: 2000),
            makeRaw(id: bm("b"), sortOrder: 3000),
        ]
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), legacy, bm("b")],
            newRowOrders: [:],
            dbRows: db
        )
        // 顺序已对 → 零写入；关键是 legacy 行被算进序列（不再被当成不存在）。
        XCTAssertTrue(result.isEmpty, "含旧形态行的有序段应零写入")

        // 打乱后逐个排查：三行的序号必须互不相同。
        let shuffled = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("b"), legacy],
            newRowOrders: [:],
            dbRows: db
        )
        let orders = db.map { shuffled[$0.id] ?? $0.sortOrder }
        XCTAssertEqual(Set(orders).count, orders.count, "混合形态不得撞号：\(orders)")
        XCTAssertNil(shuffled["live-uuid"])
    }

    /// 段内全是新行（首次落地）→ 直接用初值表，不引入额外调整。
    func test_segmentRenumber_fallsBackToPlanOrdersWhenNoExistingRows() {
        let orders = [bm("a"): 1000, bm("b"): 2000]
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a"), bm("b")],
            newRowOrders: orders,
            dbRows: []
        )
        XCTAssertEqual(result, orders)
    }

    func test_segmentRenumber_emptyWhenNothingStable() {
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [],
            newRowOrders: [:],
            dbRows: [makeRaw(id: "live-uuid")]
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// 单行（只有新行自己在段内）不得触发整形逻辑异常。
    func test_segmentRenumber_singleNewRow() {
        let result = RemoteHistorySyncCore.stableSegmentRenumber(
            orderedStableIds: [bm("a")],
            newRowOrders: [bm("a"): 1000],
            dbRows: []
        )
        XCTAssertEqual(result[bm("a")], 1000)
    }


    // MARK: - 5. 升级路径清理（supersededLegacyIds）

    /// 升级场景：老版本的 `bridge-*` 行与新的 `bm-*` 行承载同一内容 →
    /// 旧行必须列入 deleteIds，否则同一消息渲染两遍。
    func test_plan_deletesSupersededLegacyCopy() {
        let db = [
            makeRaw(id: "bridge-ns-12345678-9", sortOrder: 1000),
            makeRaw(id: bm("keep-me"), sortOrder: 2000),
        ]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("keep-me"))],
            dbRows: db,
            supersededLegacyIds: ["bridge-ns-12345678-9"]
        )
        XCTAssertEqual(plan.deleteIds, ["bridge-ns-12345678-9"])
        XCTAssertFalse(plan.isPureAppend, "有删除就不是纯追加")
    }

    /// 缺省空集 = 一个都不删（向后兼容 + 纯函数可独立推理）。
    func test_plan_deleteDefaultsToEmpty() {
        let db = [makeRaw(id: "bridge-ns-12345678-9", sortOrder: 1000)]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a"))],
            dbRows: db
        )
        XCTAssertTrue(plan.deleteIds.isEmpty)
    }

    /// 传入但 DB 中不存在的 id 不得出现在 deleteIds（避免发出无谓 DELETE）；
    /// 且 **bm- 行恒不删**（它是稳定身份正主，上游误传也必须挡住）。
    func test_plan_ignoresSupersededIdsNotInDb() {
        let db = [makeRaw(id: bm("a"), sortOrder: 1000)]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a"))],
            dbRows: db,
            supersededLegacyIds: ["bridge-ghost-1", bm("a")]
        )
        XCTAssertTrue(plan.deleteIds.isEmpty,
                      "DB 里没有的行不发 DELETE；bm- 行即使被误传入也不得删")
    }

    /// stable 段自身与 past 行不得被当成冗余副本删掉——只有 bridge- 旧形态
    /// 才可能是"同一 seq 的旧副本"（该过滤在调用方，此处锁 plan 的语义：
    /// 它只服从传入集合，不自行扩大）。
    func test_plan_doesNotWidenDeleteSet() {
        let db = [
            makeRaw(id: bm("a"), sortOrder: 1000),
            makeRaw(id: "past-ns-disk-3", sortOrder: 2000),
            makeRaw(id: "bridge-ns-12345678-9", sortOrder: 3000),
        ]
        let plan = RemoteHistorySyncCore.planStableReplace(
            stableRaws: [makeRaw(id: bm("a"))],
            dbRows: db,
            supersededLegacyIds: ["bridge-ns-12345678-9"]
        )
        XCTAssertEqual(plan.deleteIds, ["bridge-ns-12345678-9"])
        XCTAssertFalse(plan.deleteIds.contains(bm("a")))
        XCTAssertFalse(plan.deleteIds.contains("past-ns-disk-3"))
    }
}
