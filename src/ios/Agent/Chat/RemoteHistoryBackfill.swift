// 远端 session history 增量同步工具。
//
// 背景：远端 session 的 messages 在本机 DB 里有部分内容（user 消息在 2694
// 落库，assistant 消息在 runAgentLoop 5970 落库），但杀后台时若 stream 还没
// 结束 → assistant 缺一条。本类负责：进入 session 时从桥拉 history，判重
// 已有的，仅把增量 appendMessages 到 DB + 返回 UI 层。
//
// 三种使用方式：
// 1. .emptyLocal   — 本地 DB 为空，全量回填（杀后台第一次进）
// 2. .incremental  — 本地有部分消息，仅追加缺失的（杀后台第二次进）
// 3. .noop         — 本地最新 / 桥断 / 全判重，放弃本次同步
//
// 全部本地 agent session 永不调用本类（loadSession 用 isRemoteSession() 三重
// 门 gate 拦）。本类只关心远端 agent session。

import Foundation
import Combine

private let backfillLogger = AppLogger(category: "HistoryBackfill")


// MARK: - BackfillCore 纯函数（可单测，无 actor/UI 依赖）

/// 判重 + 增量决策的纯函数。可单测，无 actor / UI / DB / 桥依赖。
/// 业务规则：bridgeSeq > lastSyncedSeq 才算新增；同 id 防御性去重；
/// DB 空 → 全量替换；DB 有 → 增量追加。
enum BackfillCore {

    struct SkipCounters {
        var seq = 0
        var id = 0
    }

    struct Plan {
        let newRaws: [RawMessage]
        let skipCounters: SkipCounters
        let maxSeq: Int
    }

    /// 纯函数：给定桥 history + 本地已有 raw + 上次同步水位，返回落库计划。
    /// - Parameters:
    ///   - history: 桥端 messages（已含 bridgeSeq）
    ///   - existing: 本地 DB 已有 raw（用于 id 防御性去重）
    ///   - lastSyncedSeq: 上次已同步的最大 bridgeSeq
    ///   - buildRaw: AgentMessage → RawMessage 工厂（注入以避免循环依赖）
    static func computePlan(
        history: [AgentMessage],
        existing: [RawMessage],
        lastSyncedSeq: Int,
        buildRaw: (AgentMessage) async -> RawMessage?
    ) async -> Plan {
        let existingIds = Set(existing.compactMap { $0.id.isEmpty ? nil : $0.id })

        var newRaws: [RawMessage] = []
        var skip = SkipCounters()
        var maxSeq = lastSyncedSeq

        for agentMsg in history {
            let seq = agentMsg.bridgeSeq ?? 0
            if seq > 0 {
                maxSeq = max(maxSeq, seq)
                if seq <= lastSyncedSeq {
                    skip.seq += 1
                    continue
                }
            }
            guard let raw = await buildRaw(agentMsg) else { continue }
            if existingIds.contains(raw.id) {
                skip.id += 1
                continue
            }
            newRaws.append(raw)
        }

        return Plan(newRaws: newRaws, skipCounters: skip, maxSeq: maxSeq)
    }
}

/// 远端 history 增量同步结果（供 UI 层决策如何呈现）。
enum BackfillResult {
    case empty                                   // 本地 DB 本来就空，无 UI 变化
    case appended(messages: [ChatMessage])        // 增量追加到 UI
    case replaced(messages: [ChatMessage])        // 全量替换（DB 空时的回填）
    case noop(reason: String)                     // 跳过（本地最新 / 桥断 / 全部判重）
    case failed(error: Error)                     // 错误（供诊断日志）
}

/// 远端 history 增量同步管理器（单例 + per-session 防重入）。
///
/// [Fix 2026-09-05 bug 3] Removed `@MainActor` so `backfillIfNeeded` can be
/// called from a detached task without parking the main actor. Thread-safety
/// is provided by `lock` (NSLock) guarding `inFlight` — no actor isolation
/// needed. `ChatStore.shared` is also a regular class, so `appendMessages`
/// and `RemoteSessionMetadata` are safe to call from any executor.
final class RemoteHistoryBackfill {
    static let shared = RemoteHistoryBackfill()

    /// 正在 backfill 的 session id 集合（防重入）。
    private var inFlight: Set<String> = []
    private let lock = NSLock()

    /// 入口。返回的 messages 数量 == 桥发回的新增数（含全量回填的 entire 数组）。
    /// 调用方负责把 messages 喂给 UI（appendMessagesToUI / replaceMessages）。
    ///
    /// - Parameters:
    ///   - sessionId: 目标 session id
    ///   - remoteDeviceId: nil = 本机远端 session；非 nil = iCloud 同步来的远端
    ///   - existingRawMessages: 当前 DB 已有 raw（用于判重）
    ///   - mediaResolver: media 解析回调
    ///   - buildRawMessage: 从 AgentMessage 建 RawMessage 的工厂（由 caller 注入以避免循环依赖）
    ///   - toChatMessage: RawMessage → ChatMessage 的工厂
    ///   - chatSessionID: 桥 chat session id（可能为 nil）
    ///
    /// [Fix 2026-09-05 bug 3] `nonisolated` lets the caller (scheduleRemoteHistoryBackfill)
    /// invoke this from a `Task.detached`, so the heavy work — network fetch, dedup plan,
    /// SQLite write, UI conversion — does NOT park the main actor for 4-5 seconds while
    /// a user is staring at a frozen chat page. `ChatStore` is a regular class (not actor),
    /// so `appendMessages` and `RemoteSessionMetadata` can be called from any executor
    /// without `MainActor.run`. The only MainActor touchpoint is the final `toChatMessage`
    /// conversion when the caller passes a closure that captures MainActor state — that
    /// is the caller's problem, not ours.
    nonisolated func backfillIfNeeded(
        sessionId: String,
        remoteDeviceId: String?,
        existingRawMessages: [RawMessage],
        mediaResolver: @escaping (MediaRef) -> URL,
        buildRawMessage: @escaping (AgentMessage) async -> RawMessage?,
        toChatMessage: @escaping (RawMessage) -> ChatMessage?,
        chatSessionID: String? = nil
    ) async -> BackfillResult {

        let startedAt = CFAbsoluteTimeGetCurrent()
        backfillLogger.info("[HistoryBackfill] entry session=\(sessionId.prefix(8)) existing=\(existingRawMessages.count)")

        // === 1. 入口守卫：防重入 ===
        lock.lock()
        if inFlight.contains(sessionId) {
            lock.unlock()
            backfillLogger.info("[HistoryBackfill] session=\(sessionId.prefix(8)) in-flight, noop")
            return .noop(reason: "in-flight")
        }
        inFlight.insert(sessionId)
        lock.unlock()
        defer {
            lock.lock()
            inFlight.remove(sessionId)
            lock.unlock()
        }

        // === 2. 实例守卫：必须恰好一个远端 instance ===
        let instances = ProviderConfigStore.shared.enabledInstances(for: .remoteAgent)
        guard instances.count == 1, let instance = instances.first else {
            backfillLogger.warning("[HistoryBackfill] session=\(sessionId.prefix(8)) no remote instance configured")
            return .noop(reason: "no-remote-instance")
        }

        // === 3. 拉桥 history ===
        let history: [AgentMessage]
        do {
            guard let h = await AIChatViewModel.fetchRemoteHistory(
                instance: instance,
                chatSessionID: chatSessionID ?? sessionId,
                allowLegacyMappingFallback: true
            ) else {
                backfillLogger.warning("[HistoryBackfill] session=\(sessionId.prefix(8)) bridge fetch failed")
                return .noop(reason: "bridge-fetch-failed")
            }
            history = h
        } catch {
            backfillLogger.error("[HistoryBackfill] session=\(sessionId.prefix(8)) bridge fetch threw: \(error)")
            return .failed(error: error)
        }
        backfillLogger.info("[HistoryBackfill] session=\(sessionId.prefix(8)) bridge returned \(history.count) messages")

        // === 4. 判重 + 增量落库 ===
        // 抽到 BackfillCore.computePlan 纯函数（可单测，无 actor 依赖）
        let lastSyncedSeq = RemoteSessionMetadata.load(sessionId: sessionId)?.lastSyncedBridgeSeq ?? 0
        let plan = await BackfillCore.computePlan(
            history: history,
            existing: existingRawMessages,
            lastSyncedSeq: lastSyncedSeq,
            buildRaw: buildRawMessage
        )
        let newRaws = plan.newRaws
        let skippedBySeq = plan.skipCounters.seq
        let skippedById = plan.skipCounters.id
        let maxSeq = plan.maxSeq

        // === 5. 落库 ===
        if !newRaws.isEmpty {
            await ChatStore.shared.appendMessages(newRaws)
            backfillLogger.info("[HistoryBackfill] session=\(sessionId.prefix(8)) persisted \(newRaws.count) messages to DB")
        } else {
            backfillLogger.info("[HistoryBackfill] session=\(sessionId.prefix(8)) no new messages to persist")
        }

        // === 6. 更新水位 ===
        if maxSeq > lastSyncedSeq {
            let prev = RemoteSessionMetadata.load(sessionId: sessionId)
            let meta = RemoteSessionMetadata(
                lastSyncedBridgeSeq: maxSeq,
                lastBackfilledAt: Date(),
                totalBackfilledMessages: (prev?.totalBackfilledMessages ?? 0) + newRaws.count
            )
            RemoteSessionMetadata.save(meta, sessionId: sessionId)
        }

        // === 7. 转 ChatMessage 给 UI ===
        // [Fix 2026-09-05 bug 2] Drop orphan tool_result-only user messages here too.
        // Such a row has no real user text — bridge sent it as a standalone user-role
        // AgentMessage wrapping a single tool_result part. Rendering it would produce
        // an empty user bubble, which ccpocket official avoids by treating tool_result
        // as its own first-class message type. We can't reshape history post-hoc, so
        // we drop it at the boundary between persistence and UI.
        let newChatMessages: [ChatMessage] = newRaws.compactMap { raw in
            if raw.role == .user {
                let hasNonToolResult = raw.parts.contains { part in
                    switch part {
                    case .text: return true
                    case .toolUse: return true
                    case .toolResult: return false
                    }
                }
                if !hasNonToolResult {
                    backfillLogger.warning("orphan tool_result user-bubble dropped rawId=\(raw.id.prefix(8))")
                    return nil
                }
            }
            return toChatMessage(raw)
        }

        // === 8. 决定返回类型 ===
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        let skipSummary = "seq:\(skippedBySeq) id:\(skippedById)"
        if newChatMessages.isEmpty {
            backfillLogger.info("[HistoryBackfill] session=\(sessionId.prefix(8)) done in \(String(format: "%.0f", elapsedMs))ms new=0 skipped=\(skipSummary)")
            return .noop(reason: "all-skipped:\(skipSummary)")
        }

        // DB 空 → 全量替换；DB 有 → 增量追加
        if existingRawMessages.isEmpty {
            backfillLogger.info("[HistoryBackfill] session=\(sessionId.prefix(8)) done in \(String(format: "%.0f", elapsedMs))ms replaced=\(newChatMessages.count) skipped=\(skipSummary)")
            return .replaced(messages: newChatMessages)
        } else {
            backfillLogger.info("[HistoryBackfill] session=\(sessionId.prefix(8)) done in \(String(format: "%.0f", elapsedMs))ms appended=\(newChatMessages.count) skipped=\(skipSummary)")
            return .appended(messages: newChatMessages)
        }
    }
}

// MARK: - 元数据（per-session bridge sync 水位）

/// Per-session bridge sync metadata stored in UserDefaults.
/// 跨设备通过 iCloud sync 同步 session 行（暂不包含此字段，本机单设备优化）。
struct RemoteSessionMetadata: Codable {
    let lastSyncedBridgeSeq: Int
    let lastBackfilledAt: Date
    let totalBackfilledMessages: Int

    static let keyPrefix = "RemoteSessionMetadata.v1."

    static func load(sessionId: String) -> RemoteSessionMetadata? {
        let key = keyPrefix + sessionId
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RemoteSessionMetadata.self, from: data)
    }

    static func save(_ meta: RemoteSessionMetadata, sessionId: String) {
        let key = keyPrefix + sessionId
        if let data = try? JSONEncoder().encode(meta) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
