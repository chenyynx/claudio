import SwiftUI
import UIKit

/// Standalone "Connect Your Computer" flow — the remote-agent (CC Pocket
/// Bridge) setup page, reached from the first-launch empty state.
///
/// [Claude restyle 2026-09-05] Replaced the stock Form/Section layout with
/// an Apple-style hero + numbered-step layout. Visual language: warm ivory
/// background, monochrome char-coal CTA, monospace code blocks, hairline
/// dividers, sticky bottom action. Mirrors official app's "Connect Your
/// Computer" card visual but promotes it to a full setup page with clear
/// numbered steps (the original Form put everything in a flat list).
struct RemoteAgentSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProviderConfigStore.shared

    /// When non-nil, this page edits the existing instance instead of
    /// adding a new one (fields prefilled, save updates in place).
    private let existingInstance: ProviderInstance?

    @State private var wssURL = ""
    @State private var token = ""
    @State private var projectPath = ""
    @State private var isSaving = false
    /// [Claudio 2026-09-06 G2] Probe state for auto-fill. Set when the
    /// throwaway probe connect fails (URL bad, bridge down, token wrong)
    /// so the field hint can show "Bridge 不可达" instead of silently
    /// staying empty.
    @State private var bridgeUnreachable = false
    @State private var allowedDirs: [String] = []
    /// Auto-fill runs only when the user is creating a NEW instance AND
    /// the field is still empty — never overwrite an in-progress edit,
    /// never overwrite a saved value being shown to an editor.
    @State private var didAttemptAutofill = false
    @FocusState private var focused: Field?

    private enum Field { case url, token, path }

    init(existingInstance: ProviderInstance? = nil) {
        self.existingInstance = existingInstance
        if let instance = existingInstance {
            _wssURL = State(initialValue: instance.customBaseURL ?? "")
            _token = State(initialValue: ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? "")
            _projectPath = State(initialValue: RemoteAgentConnection.load(instanceID: instance.id)?.projectPath ?? "")
        }
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bridgeURLHost: String? {
        BridgeURLValidator.host(of: wssURL)
    }

    private var canSave: Bool {
        !trimmedToken.isEmpty && !isSaving && bridgeURLHost != nil
    }

    /// Path must be non-empty for upload/file-peek to ever work (the bridge
    /// parser silently drops empty projectPath — see G1.3 pre-flight).
    /// Skip validation when allowedDirs is non-empty AND user hasn't typed
    /// yet (placeholder mode — first connect attempt should fill it).
    private var trimmedPath: String {
        projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection
                    Divider().overlay(ClaudePalette.border)
                    step1InstallSection
                    Divider().overlay(ClaudePalette.border)
                    step2ConnectSection
                    Divider().overlay(ClaudePalette.border)
                    step3PathSection
                    // Bottom padding to keep content above the sticky CTA
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 20)
            }
            .background(ClaudePalette.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)

            stickyConnectButton
        }
        .navigationTitle("Connect Your Computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(ClaudePalette.textPrimary)
            }
        }
        .task {
            await attemptAutofill()
        }
    }

    // MARK: - G2 Auto-fill

    /// [Claudio 2026-09-06 G2] Open a throwaway Bridge connection just to
    /// pull the `session_list` (which carries `allowedDirs`). When the
    /// Bridge is reachable AND the whitelist has at least one entry, fill
    /// the empty Project Path field with `allowedDirs.first`. Multi-user
    /// principle: we never hardcode a default — the Bridge tells us what
    /// directories the user already trusts.
    ///
    /// Skipped for editing flows (`existingInstance != nil`) so we never
    /// silently overwrite a saved value with the bridge-reported default.
    /// Re-running also skipped after the first attempt — `.task` may fire
    /// multiple times on view re-entry; a flag avoids re-overwriting a
    /// field the user has typed into.
    private func attemptAutofill() async {
        guard existingInstance == nil, !didAttemptAutofill else { return }
        didAttemptAutofill = true
        let trimmedBase = wssURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedBase) else {
            bridgeUnreachable = true
            return
        }
        let probe = CCPocketClient(baseURL: baseURL, token: trimmedToken)
        probe.mappingInstanceID = nil
        do {
            try await probe.connect(projectPath: "", provider: "claude", permissionMode: "default")
            // Wait briefly for session_list to land on the receive task.
            for _ in 0..<20 {
                if !probe.allowedDirs.isEmpty || probe.state != .connected { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            allowedDirs = probe.allowedDirs
            bridgeUnreachable = false
            // [Claudio 2026-09-06 G2 UX] Auto-fill only when (a) field still
            // empty and (b) whitelist has at least one entry. The user
            // can always overwrite before tapping Save.
            if projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = allowedDirs.first {
                projectPath = first
                logger.info("autofill: filled projectPath with \(first)")
            }
        } catch {
            bridgeUnreachable = true
            logger.warning("autofill: probe connect failed: \(error.localizedDescription)")
        }
        probe.disconnect()
    }

    private let logger = AppLogger(category: "RemoteAgentSetup")
}

// [T-ios-remoteagent-qr-notif-restored] a5d9d49 refactor dropped these two
// static Notification.Name declarations by accident while rewriting the
// Connect section — but RemoteAgentSetupView still references them at the
// "Scan QR Code" button (line 170) and the onReceive at the bottom of the
// connect section (line 220). Without this extension both lines fail to
// compile with "type 'Notification.Name' has no member 'showRemoteQRScanner'
// / 'remoteQRScanResult'".
extension Notification.Name {
    static let showRemoteQRScanner = Notification.Name("showRemoteQRScanner")
    static let remoteQRScanResult = Notification.Name("remoteQRScanResult")
}


// MARK: - BridgeURLValidator

/// [Claudio 2026-09-07 P1] Bridge URL 格式校验的单一实现 — SetupView
/// 的 canSave 与 ProviderInstanceDetailView 的即时提示共用。
///
/// 背景（2026-09-06 单斜杠事故）：`wss:/host/path`（少打一个 /）会被
/// URLSessionWebSocketTask 容忍（WS 照常通），但 URLComponents 按
/// RFC3986 解析成 host=nil + 整段塞进 path —— 文件上传的 httpBaseURL
/// 派生随之失败。UI 层必须拦，同时 displayHost 给卡片/摘要一个
/// 人认得的短名（pipicore.cn → pipicore）。
enum BridgeURLValidator {
    /// 解析出 host；单斜杠形态从 path 首段兜底切出。nil = 无法解析。
    static func host(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let comps = URLComponents(string: trimmed) else { return nil }
        if let host = comps.host, !host.isEmpty { return host }
        if comps.scheme != nil, comps.path.hasPrefix("/") {
            let body = String(comps.path.dropFirst())
            if let slash = body.firstIndex(of: "/") {
                let candidate = String(body[..<slash])
                if candidate.contains("."), !candidate.isEmpty { return candidate }
            } else if body.contains(".") {
                return body
            }
        }
        return nil
    }

    /// 摘要用短名：host 去 TLD（pipicore.cn → pipicore；带端口先去端口）。
    static func displayHost(of urlString: String) -> String? {
        guard let host = host(of: urlString) else { return nil }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        let parts = name.split(separator: ".")
        if parts.count >= 2 { return String(parts[0]) }
        return name
    }
}
