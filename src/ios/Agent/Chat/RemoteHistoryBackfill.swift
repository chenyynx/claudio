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

/// 增量恢复开关（v1.14.23 Phase 2 合入；2026-09-11 pp 拍板切 true —
/// 恢复提速路径正式启用：cursor 有效且 bridgeId 匹配时只拉增量（delta），
/// 任何失败形态（连接/超时/error/终态缺失/snapshot/gap/基线缺失）→
/// fallback 全量 = v1.14.22 已验证路径，不劣于现状）。
/// 首次运行无 cursor → 自然走全量重锚，第二次起才进 delta（灰度余量）。
/// 回滚 = 把此值改回 false（cursor 残留无害，读取侧全跳过）。
enum RemoteHistorySyncConfig {
    static let useDelta = true
}

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

        // === 3. 拉桥 history（delta 优先，fallback 全量） ===
        // [三-B 规则] guard 条件里不放多行链式——先绑定中间结果再 guard。
        // [增量恢复 v1.14.23 Phase 2] 决策树（对齐官方 bridge_service.dart
        // requestSessionHistory:2838——有缓存走 delta 无缓存全量）：
        // useDelta && provider==claude && cursor 有效 → delta；
        // delta 任何失败形态（连接/超时/error/终态缺失/snapshot/gap）→
        // fallback 全量（= v1.14.22 已验证路径，不劣于现状）。
        // 有效性前提之二（DB 有 bridge-{seq} 行）在 delta 命中后校验：
        // DB 空 → cursor 不可能有意义（落库成功才写 cursor 的逆否），
        // 保守起见 delta 命中后查 dbRows 非 bridge 行才提交——见 === 5 前置。
        struct WireFetch {
            let wire: [CCPocketProtocol.ServerMessage]
            let engine: [AgentMessage]
            let bridgeId: String?
            let isDelta: Bool
            /// delta 终态信封的 toSeq（cursor 更新用；全量路径 nil）
            let deltaToSeq: Int?
        }
        var wireFetch: WireFetch?
        /// [Fix v1.14.29] 空 delta（bridge 回执"自 cursor 起无新消息"）直返用。
        /// 旧行为：空 delta 照跑校准 → `historyRaws=[]` → unified 序为空 →
        /// renumber 把所有 live UUID 行（用户**全部**发言）重排到会话末尾
        /// （pp 真机 2026-09-11 08:06 实证），且 changed=false 连 UI 都不刷新
        /// = DB 静默被写坏。现在：无新内容 → 完全不碰 DB / 顺序。
        var emptyDeltaResolved: (bridgeId: String, toSeq: Int)?
        // [审查 2026-09-11 G1] cursor 失效校验（设计文档规则「bridgeId
        // 变了 → 弃 cursor」的实现，Phase 2 初版漏做）：cursor 的 seq 空间
        // 必须 == 当前 mapping 的 bridge 会话。反例：resume 换了 bridge
        // 会话、mapping 已更新而 cursor 还钉在旧会话——若旧会话进程仍活，
        // delta 会一直「成功」返回旧空间条目（永不 fallback），新会话的
        // 消息永远同步不进来（比全量路径更差）。mapping 缺失/读不到 →
        // 保守全量（全量路径自带 bridgeId 切换检测 + cursor 重锚）。
        var deltaCursor: RemoteHistoryCursor?
        if RemoteHistorySyncConfig.useDelta,
           (RemoteAgentConnection.load(instanceID: instance.id)?.provider ?? "claude") == "claude",
           let stored = RemoteHistoryCursorStore.read(sessionId: sessionId) {
            let mappingBridgeId = CCPocketClient.persistedBridgeId(
                instanceID: instance.id,
                chatSessionID: chatSessionID ?? sessionId
            )
            if stored.bridgeId == mappingBridgeId {
                deltaCursor = stored
            } else {
                logger.warning("[HistorySync] session=\(sessionId.prefix(8)) cursor stale bridge=\(stored.bridgeId.prefix(8)) != mapping=\(mappingBridgeId?.prefix(8) ?? "nil") — fallback full")
            }
        }
        if let cursor = deltaCursor {
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) delta attempt bridge=\(cursor.bridgeId.prefix(8)) sinceSeq=\(cursor.lastSeq)")
            if let delta = await AIChatViewModel.fetchDeltaWithWire(
                instance: instance,
                chatSessionID: chatSessionID ?? sessionId,
                cursor: cursor
            ) {
                let from = delta.envelope.fromSeq ?? -1
                let to = delta.envelope.toSeq ?? -1
                let isSnapshot = delta.envelope.type == "history_snapshot"
                // 空 delta 形态（bridge getHistorySince:789-793）：from=to+1
                // entries=[]——语义"没有新消息"，合法命中。
                let emptyDelta = (from == to + 1)
                // 连续性强校验（方案 R1 对策）：delta 必须无缝衔接 cursor，
                // 否则 planReplace 的补插依赖完整 historyRaws 会被破坏。
                // [R1 对策之二·基线守卫] delta 命中但 DB 无 bridge- 前缀的
                // 非 user 行 = 无基线（DB 被清/重装后 UserDefaults 残留
                // cursor / iCloud 恢复时序）——delta 只含增量，无基线上校准
                // = 老消息永久缺失。此处 probe（本地 SQLite <10ms），无基线
                // 直接在本分支内 fallback 全量（不构建 delta WireFetch，
                // 下游派生变量全部从最终来源计算——杜绝 mid-way 替换）。
                var deltaUsable = !isSnapshot && (emptyDelta || from == cursor.lastSeq + 1)
                if deltaUsable, !isSnapshot, !emptyDelta {
                    let dbRowsProbe = await ChatStore.shared.loadMessages(sessionId: sessionId)
                    let hasBaseline = dbRowsProbe.contains {
                        $0.role != .user && $0.id.hasPrefix("bridge-")
                    }
                    if !hasBaseline {
                        logger.warning("[HistorySync] session=\(sessionId.prefix(8)) delta hit but DB has no bridge baseline — fallback full")
                        deltaUsable = false
                    } else {
                        // [Fix v1.14.29] 快路径准入（乱序根因 A 的闸门）：定序
                        // 已被全量校准封版 + 本次为纯追加，才允许跳过 renumber。
                        // 残缺的 historyRaws 交给 planReplace → unified 序只剩
                        // 新行 → renumber 会把用户全部发言重排到末尾。
                        let dbMaxBridgeSeq = dbRowsProbe
                            .compactMap { ReplayRowId.parseBridgeSeq($0.id) }
                            .max()
                        let deltaSeqs = delta.wire.compactMap { $0.historySeq }
                        let sealed = self.isOrderSealed(sessionId: sessionId, bridgeId: delta.bridgeId)
                        let fastPathAllowed = RemoteHistorySyncCore.deltaFastPathAllowed(
                            orderSealed: sealed,
                            deltaSeqs: deltaSeqs,
                            dbMaxBridgeSeq: dbMaxBridgeSeq
                        )
                        if !fastPathAllowed {
                            let dbMaxText = dbMaxBridgeSeq.map(String.init) ?? "nil"
                            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) delta fast-path denied (sealed=\(sealed) dbMaxSeq=\(dbMaxText) deltaSeqs=\(deltaSeqs.count)) — fallback full")
                            deltaUsable = false
                        }
                        // [Fix v1.14.30 / 对抗审查 2·前提 2 混合批次] 单一锚点
                        // 只对「纯尾段插入」成立。wire 级保守判据：**任何
                        // user_input 之前的条目**都意味着可能夹心（本设备认领
                        // → 它在 unified 里是非插入行，其前内容全是插入行）——
                        // 回复尾段排到新输入之后 / 多回合批次整段错位。转全量
                        // 校准（幂等自愈）；过触发的代价只是一次全量 fetch
                        // （多设备交错形态），方向安全。
                        if deltaUsable, delta.wire.dropFirst().contains(where: { $0.type == "user_input" }) {
                            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) delta mixed-turn batch (user_input not leading) — fallback full")
                            deltaUsable = false
                        }
                    }
                }
                if isSnapshot {
                    logger.warning("[HistorySync] session=\(sessionId.prefix(8)) delta → snapshot (cursor beyond trim window) — fallback full")
                } else if !emptyDelta && from != cursor.lastSeq + 1 {
                    logger.warning("[HistorySync] session=\(sessionId.prefix(8)) delta gap from=\(from) expected=\(cursor.lastSeq + 1) — fallback full")
                } else if deltaUsable {
                    if emptyDelta {
                        // [Fix v1.14.29] 空 delta 不构建 WireFetch——否则下方
                        // "未封版 → 回全量自愈"分支会被短路（wireFetch 非 nil
                        // 就跳过全量 fetch）。只记终态给直返分支决策。
                        // [Fix v1.14.30 / 对抗审查 M6] toSeq ≥ 0 守卫：空 delta
                        // 直返分支会拿 toSeq 覆写游标，而非空路径的守卫
                        // （「toSeq 合法性守卫」）在这条分支被绕过——toSeq
                        // 缺失/为 -1 时会把游标写成 -1（下次 delta 从 -1 起，
                        // 语义崩塌）。非法值不设直返 → 落到全量重锚。
                        if to >= 0 {
                            emptyDeltaResolved = (bridgeId: delta.bridgeId, toSeq: to)
                        } else {
                            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) empty delta with invalid toSeq=\(to) — fallback full")
                        }
                    } else {
                        wireFetch = WireFetch(
                            wire: delta.wire,
                            engine: RemoteAgentProvider.historyAgentMessages(
                                from: delta.wire,
                                namespace: ReplayRowId.namespace(sessionId: sessionId),
                                segment: ReplayRowId.segment(id: delta.bridgeId)
                            ),
                            bridgeId: delta.bridgeId,
                            isDelta: true,
                            deltaToSeq: to
                        )
                    }
                }
            } else {
                logger.warning("[HistorySync] session=\(sessionId.prefix(8)) delta unavailable — fallback full")
            }
        }
        // [Fix v1.14.29] 空 delta 直返：无新内容 → 完全不碰 DB / 顺序，只把
        // cursor 维持/推进到终态 toSeq（旧行为见 emptyDeltaResolved 注释）。
        // ⚠️ 例外：**未封版**会话（新装 / 刚升级 / 被旧版写坏过）不走 no-op
        // ——否则"没有新消息"的会话永远等不到那次全量自愈，乱序会一直留着。
        if let emptyDelta = emptyDeltaResolved {
            if isOrderSealed(sessionId: sessionId, bridgeId: emptyDelta.bridgeId) {
                let refreshed = RemoteHistoryCursor(bridgeId: emptyDelta.bridgeId, lastSeq: emptyDelta.toSeq)
                RemoteHistoryCursorStore.write(refreshed, sessionId: sessionId)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                logger.info("[HistorySync] session=\(sessionId.prefix(8)) empty delta — no-op, cursor kept lastSeq=\(emptyDelta.toSeq) in \(String(format: "%.0f", elapsedMs))ms")
                return RemoteHistorySyncOutcome(
                    changed: false,
                    lastWireType: nil,
                    insertedCount: 0,
                    deletedCount: 0,
                    historyCount: 0,
                    writtenCursor: refreshed
                )
            }
            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) empty delta on UNSEALED session — fallback full (one-time order heal)")
        }
        if wireFetch == nil {
            let fetched = await AIChatViewModel.fetchRemoteHistoryWithWire(
                instance: instance,
                chatSessionID: chatSessionID ?? sessionId
            )
            guard let fetched else {
                logger.warning("[HistorySync] session=\(sessionId.prefix(8)) bridge fetch failed")
                return RemoteHistorySyncOutcome(changed: false, lastWireType: nil, insertedCount: 0, deletedCount: 0, historyCount: 0)
            }
            wireFetch = WireFetch(
                wire: fetched.wire,
                engine: fetched.engine,
                bridgeId: fetched.bridgeId,
                isDelta: false,
                deltaToSeq: nil
            )
        }
        guard let resolvedFetch = wireFetch else {
            return RemoteHistorySyncOutcome(changed: false, lastWireType: nil, insertedCount: 0, deletedCount: 0, historyCount: 0)
        }
        let wireMessages = resolvedFetch.wire
        let history = resolvedFetch.engine
        let lastWireType = wireMessages.last?.type
        logger.info("[HistorySync] session=\(sessionId.prefix(8)) bridge returned \(history.count) engine messages, lastWireType=\(lastWireType ?? "nil") isDelta=\(resolvedFetch.isDelta)")

        // [排查 2026-09-10 双份渲染·终版根因] seq 是 per-bridge-session 计数。
        // resume 会换 bridge 会话 → seq 从 1 重计。bridgeId 变化 = 确定性
        // 重置信号（长度启发式在短会话上必漏——旧空间 3 行 vs 新空间 5 行
        // 时 dbMax<histMax，同 seq 不同内容照样串台）。per-chat 存储，
        // 首次同步（无存储值）视为同空间，不触发换血。
        let bridgeIdKey = "RemoteSyncBridgeId.v1.\(sessionId)"
        let storedBridgeId = UserDefaults.standard.string(forKey: bridgeIdKey)
        let currentBridgeId = resolvedFetch.bridgeId
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
        // [Fix v1.14.29] 回放行 id 命名空间一次性迁移（幂等）必须发生在读
        // dbRows **之前**——否则计划按旧 id 算 keep 集、落库按新 id 写，
        // 同一行会被当成新行重插（PK 冲突 → 内容被吞，正是要修的病）。
        // [Fix v1.14.30 / 对抗审查 A3] 换 bridge 会话（seq 空间重置）时不给
        // bridge 行迁移（segment 传 nil）：旧空间的 legacy 行被打上"当前段"
        // 后会占住新空间的同 seq（keep 命中）→ 新内容永不落库 + 用户发言被
        // 甩到末尾（每次校准复现）。它们由 planReplace 的换血规则清理。
        // past 行的身份是磁盘 transcript（与 bridge 段无关），照常迁移。
        let previousSegment = storedBridgeId.map(ReplayRowId.segment)
        let currentSegment = resolvedFetch.bridgeId.map(ReplayRowId.segment)
        let diskSegment = CCPocketClient.persistedClaudeId(
            instanceID: instance.id,
            chatSessionID: chatSessionID ?? sessionId
        ).map(ReplayRowId.segment)
        await ChatStore.shared.migrateReplayRowIdsIfNeeded(
            sessionId: sessionId,
            namespace: ReplayRowId.namespace(sessionId: sessionId),
            segment: bridgeSessionSwitched ? nil : currentSegment,
            diskSegment: diskSegment
        )
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
        // [Fix 2026-09-11] past id 空间迁移 v2（一次性）：bridge 端 disk 解析
        // 补全 tool_result/thinking 后 past-{index} 序列重排，旧残缺序列与新
        // 序列同 id 不同内容——id 命中 keep 会保住旧残缺行（修复失效）。
        // 触发条件（缺一不可）：
        // · 全量 fetch（delta 不触碰 past）
        // · 检测到"补全序列"特征（past 行带 toolResult part 或 thinking）——
        //   bridge 尚未部署补全解析时到达的是残缺序列（与旧行同内容），
        //   此时迁移无意义且会消耗一次性标记；等补全版到达再切。
        // · 标记未写（成功后写 2，失败不写、下次重试）。
        let historyHasEnrichedPast = historyRaws.contains { raw in
            guard raw.id.hasPrefix("past-") else { return false }
            if raw.reasoningContent?.isEmpty == false { return true }
            return raw.parts.contains {
                if case .toolResult = $0 { return true }
                return false
            }
        }
        let pastMigrationKey = "RemoteSyncPastIdSpace.v2.\(sessionId)"
        let needPastMigration = !resolvedFetch.isDelta
            && historyHasEnrichedPast
            && UserDefaults.standard.integer(forKey: pastMigrationKey) < 2
        let plan = RemoteHistorySyncCore.planReplace(
            historyRaws: historyRaws,
            dbRows: dbRows,
            nonEngineSeqs: nonEngineSeqs,
            forceFullReshuffle: bridgeSessionSwitched,
            evictPastRows: needPastMigration,
            currentSegment: currentSegment,
            previousSegment: previousSegment
        )
        // [乱序修复 2 2026-09-10 v1.14.22] replaceRemoteHistory **无条件执行**
        // （含 plan.isEmpty）：它的 renumber 按 plan.unifiedFinalOrderIds 全量
        // 重写 sort_order——即使删插为空也要落序。原因：v1.14.21 之前
        // ChatStore.repairSession 曾把校准写好的 bridge 序按 created_at+id
        // 字典序重写（远端会话 inversion 误判，pp 真机实锤），此后 DB 停留
        // 在乱序且校准 plan.isEmpty 永不触碰 → 顺序无法自愈。无条件 renumber
        // 幂等（同一 bridge 序每次写同一结果），一次校准即修复已污染 DB。
        // changed 判定不变（无删插不触发 UI 全量重建，避免无谓闪烁）。
        // [Fix v1.14.29] renumber 只在**全量**路径执行——delta 的 historyRaws
        // 只含增量，不构成定序契约要求的全量序（不合规的 delta 已在入口被
        // deltaFastPathAllowed 闸掉 → fallback 全量）。
        let applied = await ChatStore.shared.replaceRemoteHistory(
            sessionId: sessionId,
            plan: plan,
            finalOrder: historyRaws,
            renumber: !resolvedFetch.isDelta
        )
        if applied, needPastMigration {
            UserDefaults.standard.set(2, forKey: pastMigrationKey)
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) past id-space migration v2 applied — old past rows evicted and re-seeded")
        }
        if applied, !resolvedFetch.isDelta {
            // 全量校准成功 = 本会话顺序已封版 → 之后的 delta 才允许走快路径。
            markOrderSealed(sessionId: sessionId, bridgeId: resolvedFetch.bridgeId)
        }
        if !applied {
            logger.error("[HistorySync] session=\(sessionId.prefix(8)) replaceRemoteHistory FAILED (transaction rolled back) — DB untouched")
        }
        if !plan.inserts.isEmpty || !plan.deleteIds.isEmpty {
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) calibrated: +\(plan.inserts.count) -\(plan.deleteIds.count) kept=\(plan.keptCount) renumber=\(!resolvedFetch.isDelta)")
        } else {
            logger.info("[HistorySync] session=\(sessionId.prefix(8)) no content change (kept=\(plan.keptCount) renumber=\(!resolvedFetch.isDelta))")
        }

        let changed = !plan.inserts.isEmpty || !plan.deleteIds.isEmpty
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        logger.info("[HistorySync] session=\(sessionId.prefix(8)) done in \(String(format: "%.0f", elapsedMs))ms history=\(historyRaws.count) changed=\(changed)")

        // === 6. 游标写入（Phase 1：只写不读，零行为变化） ===
        // 落库成功（replaceRemoteHistory 返回返回即事务已 COMMIT）后才写 cursor。
        // delta 命中：lastSeq = 终态信封 toSeq（bridge 端 historyRevision，
        // 比本地 max(wireSeqs) 权威——本地只见了 seq>cursor.lastSeq 的增量）。
        // 全量路径：lastSeq = 本次 wire 序列的最大 historySeq（含 nonEngine
        // 行——游标语义是"全部 wire 消息"，不只是 engine 行）。wire 无任何
        // seq（空 history / 全为 past raw）→ 不写（cursor 语义需要至少一个
        // 锚点）。bridgeId 缺失 → 不写（无 seq 空间锚点的游标无意义）。
        // [Fix v1.14.29] 空 delta 已在上方直返（cursor 维持终态 toSeq）——旧
        // 实现"空 delta 一律作废游标"正是 full/delta 乒乓的来源：每次打开都
        // 先全量修复、2 秒后被一次空 delta 再写坏。
        var writtenCursor: RemoteHistoryCursor?
        if !applied {
            // [Fix v1.14.29] 落库失败（事务已 ROLLBACK）→ 绝不写游标，清掉让
            // 下次全量重锚（v1.14.17 教训：游标抬升与落库解耦 = 全量重拉乱序）。
            RemoteHistoryCursorStore.clear(sessionId: sessionId)
            logger.warning("[HistorySync] session=\(sessionId.prefix(8)) cursor cleared (apply failed)")
        } else if let currentBridgeId = resolvedFetch.bridgeId {
            let lastSeq: Int?
            // [审查 2026-09-11] toSeq 合法性守卫：协议保证 delta 终态带
            // toSeq，缺失/负值（-1 哨兵）说明桥端形态异常——不信任，退回
            // 本地可见 max（delta 条目完整时语义等价）。
            if resolvedFetch.isDelta, let toSeq = resolvedFetch.deltaToSeq, toSeq >= 0 {
                lastSeq = toSeq
            } else {
                lastSeq = wireMessages.compactMap { $0.historySeq }.max()
            }
            if let lastSeq {
                let cursor = RemoteHistoryCursor(bridgeId: currentBridgeId, lastSeq: lastSeq)
                RemoteHistoryCursorStore.write(cursor, sessionId: sessionId)
                writtenCursor = cursor
                logger.info("[HistorySync] session=\(sessionId.prefix(8)) cursor written bridge=\(currentBridgeId.prefix(8)) lastSeq=\(lastSeq) isDelta=\(resolvedFetch.isDelta)")
            } else {
                RemoteHistoryCursorStore.clear(sessionId: sessionId)
                logger.info("[HistorySync] session=\(sessionId.prefix(8)) cursor cleared (no seq anchor)")
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

    // MARK: - 定序封版标记（[Fix v1.14.29]）

    /// 本会话顺序是否已被一次成功的**全量**校准写死（renumber 1..M）。
    ///
    /// delta 快路径只允许在封版后走（见 `deltaFastPathAllowed`）：未封版的
    /// 会话——新装、刚升级到本版、DB 曾被旧版写坏——一律先跑一次全量，
    /// 天然完成旧数据自愈（顺序复位 + 被吞的行重插）。
    /// per-chat UserDefaults，值 = 封版时的 bridge 会话 id（换了会话即失效）。
    private func isOrderSealed(sessionId: String, bridgeId: String?) -> Bool {
        guard let bridgeId else { return false }
        return RemoteSyncOrderSeal.sealedBridgeId(sessionId: sessionId) == bridgeId
    }

    private func markOrderSealed(sessionId: String, bridgeId: String?) {
        guard let bridgeId else { return }
        RemoteSyncOrderSeal.mark(sessionId: sessionId, bridgeId: bridgeId)
    }
}

/// 定序封版标记存取（[Fix v1.14.29] 设计；[Fix v1.14.30] 从 Backfill 私有方法
/// 提为独立类型——**非校准路径也要能失效它**）。
///
/// 语义：值 = 完成一次成功**全量**校准时的 bridge 会话 id（bridge 会话换了
/// 即自动失效）。`deltaFastPathAllowed` 只在整个会话已封版时放行 delta 快
/// 路径（跳过 renumber）；未封版一律先跑一次全量（天然完成旧数据自愈）。
///
/// [Fix v1.14.30 / 对抗审查 M3] 为什么必须有失效通道：封版是一次性的，但
/// **非校准路径**也会改写顺序——iCloud 合并插入（mergeRemoteMessage 让位
/// +1）、裁剪（pruneOldMessages 删头部）、截断（deleteMessagesAfter）。外部
/// 改动后 delta 继续放行（纯追加、永不重排）→ 错位长期不自愈。清标记的代价
/// 只是下一次多跑一次全量（幂等、无副作用），方向安全。
enum RemoteSyncOrderSeal {

    private static func key(sessionId: String) -> String {
        "RemoteSyncOrderSealed.v1.\(sessionId)"
    }

    static func sealedBridgeId(sessionId: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(sessionId: sessionId))
    }

    static func mark(sessionId: String, bridgeId: String, defaults: UserDefaults = .standard) {
        defaults.set(bridgeId, forKey: key(sessionId: sessionId))
    }

    /// 失效：非校准路径改动了 messages 的顺序/集合后调用。
    static func clear(sessionId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(sessionId: sessionId))
    }
}
