// 远端 session 桥同步状态页（全局 Settings 入口）。
//
// 显示：
// 1. 远端 agent provider 连接状态（实时刷新）
// 2. 各 session 的本地 DB 行数（[Fix 2026-09-10 v1.14.18] 水位机制已退役，
//    恢复 = 全量校准，无水位概念）
// 3. 操作：Clear Local Cache（清空本地 messages）
//
// 数据来源：
// - ProviderConfigStore.shared.enabledInstances(for: .remoteAgent) — provider 列表
// - ChatStore.shared.listSessions() — 列出远端 session（source=remoteBridge）
//
// 与 iCloud Sync（多设备同步）是独立概念：
// - iCloud Sync：本机 DB ↔ 其他 iOS 设备（CKEngine）
// - Remote Bridge Sync：本机 DB ↔ 桥服务器（get_history + replaceEntries）
// 本 view 只关心后者。

import SwiftUI
import Combine

private let syncViewLogger = AppLogger(category: "RemoteSyncView")

@MainActor
struct RemoteSessionSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var instances: [ProviderInstance] = []
    @State private var sessions: [ChatSession] = []
    @State private var bridgeStatusText: String = "未知"
    @State private var lastRefresh: Date = Date()
    @State private var clearing: Set<String> = []
    @State private var syncRowCounts: [String: Int] = [:]
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: bridgeIcon)
                        .foregroundStyle(bridgeColor)
                    Text(bridgeStatusText)
                    Spacer()
                    Text(lastRefreshText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Bridge Status")
            } footer: {
                Text("本地 cache 与远端 bridge 之间的同步状态。")
                    .font(.caption)
            }
            .onReceive(refreshTimer) { _ in
                refreshAll()
            }
            .onAppear { refreshAll() }

            if instances.isEmpty {
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("未配置远端 agent provider")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Remote Providers")
                } footer: {
                    Text("在 Settings → Manage Providers 里添加一个 Remote Agent 类型的 provider 才能使用远端 session。")
                        .font(.caption)
                }
            } else {
                Section {
                    ForEach(instances) { inst in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(inst.label).font(.headline)
                                Spacer()
                                if !inst.isEnabled {
                                    Text("DISABLED")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                }
                            }
                            if let url = inst.customBaseURL {
                                Text(url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                } header: {
                    Text("Remote Providers")
                }
            }

            if !remoteSessions.isEmpty {
                Section {
                    ForEach(remoteSessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    Text("Session Sync Status")
                } footer: {
                    Text("恢复 = 与桥端 history 全量校准（official replaceEntries 语义），无水位概念。\nClear Local Cache 会清空本地 messages 表，下次进入该 session 时重新从桥拉取。")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Remote Bridge Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sessionRow(_ session: ChatSession) -> some View {
        // [Fix 2026-09-10 v1.14.18] RemoteSessionMetadata 水位机制已退役
        // （恢复=全量校准，无水位概念）——诊断页改为展示 DB 行数。
        let rowCount = syncRowCounts[session.id] ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.title ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            HStack(spacing: 12) {
                Text("Local rows: \(rowCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Sync = full calibration against bridge history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    Task { await clearLocalCache(session: session) }
                } label: {
                    if clearing.contains(session.id) {
                        ProgressView()
                    } else {
                        Label("Clear Local Cache", systemImage: "trash")
                            .font(.caption)
                    }
                }
                .disabled(clearing.contains(session.id))
            }
        }
        .padding(.vertical, 4)
    }

    private var remoteSessions: [ChatSession] {
        sessions.filter { $0.source == "remoteBridge" }
    }

    private var bridgeIcon: String {
        if instances.isEmpty { return "questionmark.circle" }
        if bridgeStatusText.contains("已连接") { return "checkmark.circle.fill" }
        if bridgeStatusText.contains("连接中") { return "arrow.triangle.2.circlepath" }
        if bridgeStatusText.contains("断开") { return "xmark.circle.fill" }
        return "circle.dotted"
    }

    private var bridgeColor: Color {
        if bridgeStatusText.contains("已连接") { return .green }
        if bridgeStatusText.contains("连接中") { return .orange }
        if bridgeStatusText.contains("断开") { return .red }
        return .secondary
    }

    private var lastRefreshText: String {
        let elapsed = Int(Date().timeIntervalSince(lastRefresh))
        if elapsed < 5 { return "刚刚" }
        if elapsed < 60 { return "\(elapsed)秒前" }
        return "\(elapsed / 60)分钟前"
    }

    private func refreshAll() {
        instances = ProviderConfigStore.shared.enabledInstances(for: .remoteAgent)
        let states = RemoteAgentStore.shared.liveStates()
        if states.isEmpty {
            bridgeStatusText = "空闲（无活跃 client）"
        } else if states.contains(.connected) {
            bridgeStatusText = "已连接"
        } else if states.contains(.connecting) {
            bridgeStatusText = "连接中…"
        } else if states.allSatisfy({ if case .failed = $0 { return true }; return false }) {
            bridgeStatusText = "断开"
        } else {
            bridgeStatusText = "未知状态"
        }
        Task {
            let all = await ChatStore.shared.listSessions()
            sessions = all
            for session in all {
                let stats = await ChatStore.shared.sessionWriteStats(sessionId: session.id)
                syncRowCounts[session.id] = stats.count
            }
        }
        lastRefresh = Date()
    }

    private func clearLocalCache(session: ChatSession) async {
        clearing.insert(session.id)
        defer { clearing.remove(session.id) }
        syncViewLogger.info("[RemoteSyncView] clear local cache session=\(session.id.prefix(8))")
        await ChatStore.shared.deleteMessages(sessionId: session.id)
        syncRowCounts[session.id] = 0
        refreshAll()
    }
}
