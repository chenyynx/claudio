import SwiftUI

/// [Claudio 2026-09-06 G3.3] Edit-only modal for a remote-agent instance's
/// `Project Path`. Reached from the provider card long-press menu or from
/// Settings → Providers. Auto-detects the Bridge's `BRIDGE_ALLOWED_DIRS`
/// (already exposed in `session_list`, parsed into `client.allowedDirs`)
/// so the "Reset to Auto" button always reflects the live bridge config,
/// not a stale snapshot.
///
/// Save semantics:
///   - Persists to `RemoteAgentConnection` (the only source of truth that
///     `RemoteAgentProvider.init` actually reads at L85 — see also G1.1).
///   - Releases the live connection so the *next* turn restarts with the
///     new CWD. Mid-turn writes still ride the old session; that's
///     intentional (the running Claude session has tool state, history,
///     and pending file paths that re-anchoring would lose).
///
/// Past-first-use errors (`project_path_not_configured` etc.) come through
/// `RemoteAgentConfigErrorProvider` instead — this view is for the happy
/// path of editing an already-configured instance.
struct RemoteAgentEditPathView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProviderConfigStore.shared

    private let instanceID: String

    @State private var projectPath: String = ""
    @State private var savedPath: String = ""
    @State private var allowedDirs: [String] = []
    @State private var isLoadingAllowedDirs = false
    @State private var isSaving = false
    @State private var bridgeUnreachable = false
    @FocusState private var focused: Bool

    init(instanceID: String) {
        self.instanceID = instanceID
        let initial = RemoteAgentConnection.load(instanceID: instanceID)?.projectPath ?? ""
        _projectPath = State(initialValue: initial)
        _savedPath = State(initialValue: initial)
    }

    private var trimmedPath: String {
        projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// canSave when (a) path non-empty and (b) either no whitelist or path
    /// is in the whitelist. Whitelist mismatch = silent upload failure at
    /// the bridge (`file_upload_not_allowed`), so block it at save time
    /// instead of letting the user find out via a generic error bubble.
    private var canSave: Bool {
        guard !trimmedPath.isEmpty, !isSaving else { return false }
        if !allowedDirs.isEmpty, !allowedDirs.contains(trimmedPath) { return false }
        return trimmedPath != savedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pathHint: String? {
        if trimmedPath.isEmpty {
            return "Project Path 不能为空"
        }
        if !allowedDirs.isEmpty, !allowedDirs.contains(trimmedPath) {
            return "路径不在 Bridge 白名单内（请用下方 'Reset to Auto' 或编辑 Bridge 启动配置）"
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    descriptionSection
                    fieldSection
                    if let hint = pathHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    allowedDirsSection
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Edit Project Path")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .task {
                await loadAllowedDirs()
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: - Sections

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folder the agent runs in")
                .font(.headline)
            // [Claudio 2026-09-06 G4 honest UX] Saving disconnects the live
            // socket so the next turn reopens with the new CWD — there's
            // no in-place "update cwd" wire call. Mid-turn saves will end
            // the current agent session; the new path applies to the
            // NEXT message the user sends. (Soft cost: ~1-2s reconnect
            // + Claude SDK process restart.)
            Text("Saving disconnects the live Bridge session so the next message starts in the new folder. Mid-turn sessions end; the next message picks up the new path.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Project Path".uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            TextField("/path/to/project", text: $projectPath)
                .focused($focused)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.default)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(focused ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: focused ? 1.5 : 0.5)
                }
        }
    }

    @ViewBuilder
    private var allowedDirsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bridge 白名单".uppercased())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                if isLoadingAllowedDirs {
                    ProgressView().scaleEffect(0.7)
                } else if !allowedDirs.isEmpty {
                    Button {
                        if let first = allowedDirs.first { projectPath = first }
                    } label: {
                        Label("Reset to Auto", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if bridgeUnreachable {
                Label("Bridge 不可达，无法读取白名单", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if allowedDirs.isEmpty {
                Text("Bridge 未配置白名单（任意路径都可填，Bridge 端会自己校验）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allowedDirs, id: \.self) { dir in
                        Button {
                            projectPath = dir
                        } label: {
                            HStack {
                                Image(systemName: trimmedPath == dir ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(trimmedPath == dir ? Color.accentColor : Color.secondary.opacity(0.5))
                                Text(dir)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// Open a throwaway connection on the same URL/token to fetch the live
    /// `allowedDirs` from `session_list`. The throwaway is not retained in
    /// `RemoteAgentStore`, so it does not evict this conversation's live
    /// connection (mirrors the backfill / stop-session patterns in
    /// `AIChatViewModel+ProviderFactory.swift`).
    private func loadAllowedDirs() async {
        guard let instance = store.instance(for: instanceID),
              let urlString = instance.effectiveCustomBaseURL,
              let baseURL = URL(string: urlString) else { return }
        isLoadingAllowedDirs = true
        defer { isLoadingAllowedDirs = false }
        let token = ProviderKeychainHelper.loadAPIKey(instanceId: instanceID) ?? ""
        let probe = CCPocketClient(baseURL: baseURL, token: token)
        probe.mappingInstanceID = nil
        do {
            // projectPath "" — we're not starting an agent session, just
            // poking the Bridge to receive one `session_list` reply.
            try await probe.connect(projectPath: "", provider: "claude", permissionMode: "default")
            // Poll briefly: the Bridge sends session_list on connect, but
            // dispatch happens on the receive task; small wait covers the
            // latency without a full async-awaitable callback chain.
            for _ in 0..<20 {
                if !probe.allowedDirs.isEmpty || probe.state != .connected { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            allowedDirs = probe.allowedDirs
            bridgeUnreachable = false
        } catch {
            logger.warning("editPath: probe connect failed: \(error.localizedDescription)")
            bridgeUnreachable = true
        }
        probe.disconnect()
    }

    private func save() {
        isSaving = true
        var updated = RemoteAgentConnection.load(instanceID: instanceID) ?? RemoteAgentConnection(projectPath: "")
        let previous = updated.projectPath
        updated.projectPath = trimmedPath
        RemoteAgentConnection.save(updated, instanceID: instanceID)

        // [Claudio 2026-09-06 G4] Hot-swap trigger. Release every live
        // connection for this instance — the next turn's `makeRemoteAgentProvider`
        // will read the new path from disk and pass it to a fresh
        // `RemoteAgentProvider.init`. The store key includes `chatSessionID`,
        // so we sweep all chats for this instance; sub-task / detached
        // connections (chatSessionID == nil) are released too.
        if previous != trimmedPath {
            RemoteAgentStore.shared.releaseAll(forInstanceID: instanceID)
            logger.info("editPath: saved new path for \(instanceID.prefix(8)) — released live connections")
        }
        isSaving = false
        dismiss()
    }

    private let logger = AppLogger(category: "RemoteAgentEditPath")
}