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

/// 远端 history 增量同步结果（供 UI 层决策如何呈现）。
enum BackfillResult {
    case empty                                   // 本地 DB 本来就空，无 UI 变化
    case appended(messages: [ChatMessage])        // 增量追加到 UI
    case replaced(messages: [ChatMessage])        // 全量替换（DB 空时的回填）
    case noop(reason: String)                     // 跳过（本地最新 / 桥断 / 全部判重）
    case failed(error: Error)                     // 错误（供诊断日志）
}

/// 远端 history 增量同步管理器（单例 + per-session 防重入）。
@MainActor
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
    func backfillIfNeeded(
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
        let existingIds = Set(existingRawMessages.compactMap { $0.id.isEmpty ? nil : $0.id })
        let lastSyncedSeq = RemoteSessionMetadata.load(sessionId: sessionId)?.lastSyncedBridgeSeq ?? 0

        var newRaws: [RawMessage] = []
        var skippedBySeq = 0
        var skippedById = 0
        var maxSeq = lastSyncedSeq

        for agentMsg in history {
            // 4a. seq 增量判断（核心判重）
            let seq = agentMsg.bridgeSeq ?? 0
            if seq > 0 {
                maxSeq = max(maxSeq, seq)
                if seq <= lastSyncedSeq {
                    skippedBySeq += 1
                    continue
                }
            }

            // 4b. 转 RawMessage
            guard let raw = await buildRawMessage(agentMsg) else {
                continue
            }
            // 4c. id 二次检查（防御性，本地已有同 id 不重复写）
            if existingIds.contains(raw.id) {
                skippedById += 1
                continue
            }
            newRaws.append(raw)
        }

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
        let newChatMessages: [ChatMessage] = newRaws.compactMap { raw in
            toChatMessage(raw)
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
