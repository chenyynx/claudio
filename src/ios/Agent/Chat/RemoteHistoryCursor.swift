// RemoteHistoryCursor — delta 游标与其 UserDefaults 存取（[G-3 2026-09-12] 从
// RemoteHistoryBackfill.swift 整段抽出，纯位移零行为变化）。独立成文件是为了
// 进 RemoteHistoryKit 镜像包（纯 Foundation：Codable + UserDefaults），让
// cursorStore_roundTrip 用例可被 `swift test` 真跑。

import Foundation

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
