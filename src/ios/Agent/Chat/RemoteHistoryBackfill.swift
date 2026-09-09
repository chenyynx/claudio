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
        if !plan.inserts.isEmpty || !plan.deleteIds.isEmpty {
            await ChatStore.shared.replaceRemoteHistory(
                sessionId: sessionId,
                plan: plan,
                finalOrder: historyRaws
            )
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) calibrated: +\(plan.inserts.count) -\(plan.deleteIds.count) kept=\(plan.keptCount)")
        } else {
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) already in sync (kept=\(plan.keptCount))")
        }

        let changed = !plan.inserts.isEmpty || !plan.deleteIds.isEmpty
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        logger.info("[HistorySync] session=\(sessionId.prefix(8)) done in \(String(format: "%.0f", elapsedMs))ms history=\(historyRaws.count) changed=\(changed)")
        return RemoteHistorySyncOutcome(
            changed: changed,
            lastWireType: lastWireType,
            insertedCount: plan.inserts.count,
            deletedCount: plan.deleteIds.count,
            historyCount: historyRaws.count
        )
    }
}
