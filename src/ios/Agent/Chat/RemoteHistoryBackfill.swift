// 远端 session history 校准管线（官方 replaceEntries 语义）。
//
// [Fix 2026-09-10 v1.14.18] 本文件从"增量 backfill"整体重写为"全量校准"：
// - 删除 RemoteSessionMetadata 水位（只抬最终轮 → 工具轮杀后台水位=0 → 全量重拉乱序）
// - 删除 BackfillCore 增量判定（live UUID 与回放 bridge-{seq} 两套 id 不相交）
// - 删除 contentFingerprint 指纹（prefix(3)+前 80 字有误撞/漏挡盲区）
// - 新语义：fetch 全量 history → planReplace 校准计划 → 单事务落库 → UI 重建。
//   bridge history 是唯一真相（对齐 ccpocket get_history + replaceEntries）。
//
// 全部本地 agent session 永不调用本类（loadSession 用 isRemoteSession() 三重
// 门 gate 拦）。本类只关心远端 agent session。

import Foundation

/// 校准结果（供 UI 层决策）。
struct RemoteHistorySyncOutcome {
    /// 校准是否产生变化（inserts/deletes 非空）
    let changed: Bool
    /// bridge history 末条 wire type（供恢复态 isProcessing 判定）
    let lastWireType: String?
    /// 诊断统计
    let insertedCount: Int
    let deletedCount: Int
    let historyCount: Int
    /// 本次校准实际写入的游标（诊断/测试用；nil = 未写入）
    var writtenCursor: RemoteHistoryCursor? = nil
}

/// [增量恢复 v1.14.23] per-chat 校准游标。
///
/// 语义：本地 DB 已确认持有 `bridgeId` 会话 ≤ `lastSeq` 的**全部** wire
/// 消息（含 nonEngine 行）。仅在 planReplace 校准**落库成功后**写入——
/// 落库是唯一原子真相点，fetch 成功但落库失败绝不写（v1.14.17 水位
/// 教训：水位抬升与落库解耦导致全量重拉乱序）。
///
/// 读取侧（Phase 2 启用）invalidation 规则（任一命中即弃 cursor 走全量）：
/// cursor 为 nil / bridgeId 变了 / DB 无 bridge-{seq} 行 / provider 非 claude。
/// 本 Phase（1）只写不读：线上行为与 v1.14.22 完全一致，仅积攒游标
/// 健康度数据，Phase 2 的 delta fetch 决策树合入后开始消费。
struct RemoteHistoryCursor: Codable, Equatable {
    /// 游标所属的 bridge 会话 id（seq 是 per-bridge-session 计数，
    /// bridgeId 变化 = seq 空间重置 = cursor 必须作废）
    let bridgeId: String
    /// 已确认连续持有的最大 wire seq
    let lastSeq: Int
}

/// 游标 UserDefaults 存取（独立类型便于单测注入）。
/// 单 key 原子读写（bridgeId+lastSeq 打包 JSON），不存在半新半旧状态。
enum RemoteHistoryCursorStore {
    private static func key(for sessionId: String) -> String {
        "RemoteHistoryCursor.v2.\(sessionId)"
    }

    static func read(sessionId: String, defaults: UserDefaults = .standard) -> RemoteHistoryCursor? {
        guard let data = defaults.data(forKey: key(for: sessionId)) else { return nil }
        return try? JSONDecoder().decode(RemoteHistoryCursor.self, from: data)
    }

    static func write(_ cursor: RemoteHistoryCursor, sessionId: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(cursor) {
            defaults.set(data, forKey: key(for: sessionId))
        }
    }

    static func clear(sessionId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: sessionId))
    }
}

/// 远端 history 校准管理器（单例 + per-session 防重入）。
///
/// `nonisolated` + NSLock：重活在调用方的 Task.detached 上跑，不占主线程
/// （v1.14.5 "点进聊天页冻结 4-5 秒"教训）。ChatStore 是 regular class，
/// SQLite 方法可在任意 executor 调用。
final class RemoteHistoryBackfill {
    static let shared = RemoteHistoryBackfill()

    /// 正在校准的 session id 集合（防重入；loadSession 重入会再次调度本管线）
    private var inFlight: Set<String> = []
    private let lock = NSLock()

    private let logger = AppLogger(category: "HistoryBackfill")

    /// 入口：全量拉 bridge history → 校准落库。
    ///
    /// - Parameters:
    ///   - sessionId: 目标 session id（Claudio 本地会话 id）
    ///   - buildRawMessage: AgentMessage → RawMessage 工厂（caller 注入，
    ///     复用 AIChatViewModel.buildRawMessage 的 parts 编码逻辑）
    ///   - chatSessionID: 桥 chat session id
    /// - Returns: 校准结果；bridge 断开 / 无实例时 changed=false
    nonisolated func syncIfNeeded(
        sessionId: String,
        buildRawMessage: @escaping (AgentMessage) async -> RawMessage?,
        chatSessionID: String? = nil
    ) async -> RemoteHistorySyncOutcome {
        let startedAt = CFAbsoluteTimeGetCurrent()
        logger.info("[HistorySync] entry session=\(sessionId.prefix(8))")

        // === 1. 入口守卫：防重入 ===
        let alreadyInFlight: Bool = lock.withLock {
            if inFlight.contains(sessionId) { return true }
            inFlight.insert(sessionId)
            return false
        }
        if alreadyInFlight {
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) in-flight, skip")
            return RemoteHistorySyncOutcome(changed: false, lastWireType: nil, insertedCount: 0, deletedCount: 0, historyCount: 0)
        }
        defer {
            lock.withLock { inFlight.remove(sessionId) }
        }

        // === 2. 实例守卫：必须恰好一个远端 instance ===
        let instances = await ProviderConfigStore.shared.enabledInstances(for: .remoteAgent)
        guard instances.count == 1, let instance = instances.first else {
            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) no remote instance configured")
            return RemoteHistorySyncOutcome(changed: false, lastWireType: nil, insertedCount: 0, deletedCount: 0, historyCount: 0)
        }

        // === 3. 拉桥 history（wire 原始消息，含 type 序列） ===
        // [三-B 规则] guard 条件里不放多行链式——先绑定中间结果再 guard。
        let fetched = await AIChatViewModel.fetchRemoteHistoryWithWire(
            instance: instance,
            chatSessionID: chatSessionID ?? sessionId
        )
        guard let fetched else {
            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) bridge fetch failed")
            return RemoteHistorySyncOutcome(changed: false, lastWireType: nil, insertedCount: 0, deletedCount: 0, historyCount: 0)
        }
        let wireMessages = fetched.wire
        let history = fetched.engine
        let lastWireType = wireMessages.last?.type
        logger.info("[HistorySync] session=\(sessionId.prefix(8)) bridge returned \(history.count) engine messages, lastWireType=\(lastWireType ?? "nil")")

        // [排查 2026-09-10 双份渲染·终版根因] seq 是 per-bridge-session 计数。
        // resume 会换 bridge 会话 → seq 从 1 重计。bridgeId 变化 = 确定性
        // 重置信号（长度启发式在短会话上必漏——旧空间 3 行 vs 新空间 5 行
        // 时 dbMax<histMax，同 seq 不同内容照样串台）。per-chat 存储，
        // 首次同步（无存储值）视为同空间，不触发换血。
        let bridgeIdKey = "RemoteSyncBridgeId.v1.\(sessionId)"
        let storedBridgeId = UserDefaults.standard.string(forKey: bridgeIdKey)
        let currentBridgeId = fetched.bridgeId
        let bridgeSessionSwitched: Bool
        if let stored = storedBridgeId, let current = currentBridgeId {
            bridgeSessionSwitched = stored != current
        } else {
            bridgeSessionSwitched = false
        }
        if bridgeSessionSwitched {
            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) BRIDGE SESSION SWITCHED \(storedBridgeId?.prefix(8) ?? "nil") → \(currentBridgeId?.prefix(8) ?? "nil") — seq space reset, full reshuffle")
        }
        if let current = currentBridgeId, current != storedBridgeId {
            UserDefaults.standard.set(current, forKey: bridgeIdKey)
        }

        // === 4. 逐条转换（复用 buildRawMessage；tool_result/user_input 行
        //     已在 agentMessage(fromServer:) 注入 bridgeSeq → 稳定 id） ===
        var historyRaws: [RawMessage] = []
        for agentMsg in history {
            if let raw = await buildRawMessage(agentMsg) {
                historyRaws.append(raw)
            }
        }

        // === 5. 校准计划 + 单事务落库 ===
        let dbRows = await ChatStore.shared.loadMessages(sessionId: sessionId)
        // nonEngineSeqs：wire history 里存在但不转 engine 的 seq（result/
        // status 等）——落这些 seq 的 DB 行必是错绑残留（旧 live 把 result
        // 的 seq 错注入 assistant 行）→ planReplace 判定删除。
        let nonEngineSeqs = Set(wireMessages.compactMap { msg -> Int? in
            guard let seq = msg.historySeq else { return nil }
            switch msg.type {
            case "assistant", "user_input", "tool_result":
                return nil
            default:
                return seq
            }
        })
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: historyRaws,
            dbRows: dbRows,
            nonEngineSeqs: nonEngineSeqs,
            forceFullReshuffle: bridgeSessionSwitched
        )
        // [乱序修复 2 2026-09-10 v1.14.22] replaceRemoteHistory **无条件执行**
        // （含 plan.isEmpty）：它的 renumber 按 plan.unifiedFinalOrderIds 全量
        // 重写 sort_order——即使删插为空也要落序。原因：v1.14.21 之前
        // ChatStore.repairSession 曾把校准写好的 bridge 序按 created_at+id
        // 字典序重写（远端会话 inversion 误判，pp 真机实锤），此后 DB 停留
        // 在乱序且校准 plan.isEmpty 永不触碰 → 顺序无法自愈。无条件 renumber
        // 幂等（同一 bridge 序每次写同一结果），一次校准即修复已污染 DB。
        // changed 判定不变（无删插不触发 UI 全量重建，避免无谓闪烁）。
        await ChatStore.shared.replaceRemoteHistory(
            sessionId: sessionId,
            plan: plan,
            finalOrder: historyRaws
        )
        if !plan.inserts.isEmpty || !plan.deleteIds.isEmpty {
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) calibrated: +\(plan.inserts.count) -\(plan.deleteIds.count) kept=\(plan.keptCount)")
        } else {
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) renumber-only (already in sync, order rewritten, kept=\(plan.keptCount))")
        }

        let changed = !plan.inserts.isEmpty || !plan.deleteIds.isEmpty
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        logger.info("[HistorySync] session=\(sessionId.prefix(8)) done in \(String(format: "%.0f", elapsedMs))ms history=\(historyRaws.count) changed=\(changed)")

        // === 6. 游标写入（Phase 1：只写不读，零行为变化） ===
        // 落库成功（replaceRemoteHistory 返回即事务已 COMMIT）后才写 cursor。
        // lastSeq 取本次 wire 序列的最大 historySeq（含 nonEngine 行——游标
        // 语义是"全部 wire 消息"，不只是 engine 行）。wire 无任何 seq（空
        // history / 全为 past raw）→ 不写（cursor 语义需要至少一个锚点）。
        // bridgeId 缺失 → 不写（无 seq 空间锚点的游标无意义）。
        var writtenCursor: RemoteHistoryCursor?
        if let currentBridgeId = fetched.bridgeId {
            let wireSeqs = wireMessages.compactMap { $0.historySeq }
            if let maxSeq = wireSeqs.max() {
                let cursor = RemoteHistoryCursor(bridgeId: currentBridgeId, lastSeq: maxSeq)
                RemoteHistoryCursorStore.write(cursor, sessionId: sessionId)
                writtenCursor = cursor
                logger.info("[HistorySync] session=\(sessionId.prefix(8)) cursor written bridge=\(currentBridgeId.prefix(8)) lastSeq=\(maxSeq)")
            }
        }
        return RemoteHistorySyncOutcome(
            changed: changed,
            lastWireType: lastWireType,
            insertedCount: plan.inserts.count,
            deletedCount: plan.deleteIds.count,
            historyCount: historyRaws.count,
            writtenCursor: writtenCursor
        )
    }
}
