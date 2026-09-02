import SwiftUI

/// Result of the new-session sheet: either start an on-device session or
/// start a remote Claude session with the chosen options.
enum RemoteNewSessionResult {
    case onDevice
    case claude(ClaudeSessionOptions)
}

/// Options for a remote Claude session start (aligned with the official
/// new_session_sheet → ClientMessage.start field set).
struct ClaudeSessionOptions: Equatable {
    var projectPath: String = ""
    var permissionMode: String = "default"
    var executionMode: String = "default"
    var planMode: Bool = false
    var model: String?
    var effort: String?
    var sandboxMode: String = "off"
    var useWorktree: Bool = false
    var worktreeBranch: String?
    var maxTurns: Int?
    var maxBudgetUsd: Double?
    var fallbackModel: String?
    var forkSession: Bool = false
    var persistSession: Bool = true
}

/// Official Anthropic design tokens, extracted from the live anthropic.com
/// stylesheet (2026-09-02; light surfaces hue-neutralized same day per pp —
/// the ivory read too yellow on device): page bg #F7F7F5, slate-dark
/// #141413 (text + primary button), cloud-dark #868684 (secondary text),
/// borders slate @10%, and the app-level accent orange #D97757. Dark-mode
/// surfaces follow the Claude app (#262624 background / #30302E cards).
enum ClaudePalette {
    static let background = dynamic(0xF7F7F5, 0x262624)
    static let card = dynamic(0xFFFFFF, 0x30302E)
    static let textPrimary = dynamic(0x141413, 0xFAF9F5)
    static let textSecondary = dynamic(0x868684, 0xB0AEA5)
    static let accent = Color(UIColor(hex: 0xD97757))
    static let ctaBackground = dynamic(0x141413, 0xFAF9F5)
    static let ctaForeground = dynamic(0xFAF9F5, 0x141413)
    /// Card fill — one step darker than the page background, flat and
    /// borderless (was anthropic.com ivory-medium #F0EEE6; hue neutralized —
    /// pp: too yellow on device, 2026-09-02).
    static let cardFill = dynamic(0xF0F0EE, 0x30302E)
    /// Selection/link blue — the official app marks the chosen row and
    /// inline links with a calm blue rather than the brand orange.
    static let selectionBlue = dynamic(0x4A90D9, 0x6FB1E8)

    static var border: Color {
        adaptive(0x141413, alpha: 0.1, darkHex: 0xFAF9F5, darkAlpha: 0.14)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    private static func adaptive(_ light: UInt32, alpha: Double, darkHex: UInt32, darkAlpha: Double) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: darkHex, alpha: darkAlpha)
                : UIColor(hex: light, alpha: alpha)
        })
    }
}

/// Settings-page surface: hides the system grouped gray and paints the
/// session-open palette background so every settings screen reads as one
/// ivory surface (pp 2026-09-02: settings background = session-open
/// background, everywhere).
struct SettingsPaletteBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(ClaudePalette.background)
    }
}

extension View {
    func settingsPaletteBackground() -> some View {
        modifier(SettingsPaletteBackground())
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// New-session sheet: three tabs (On-Device / Claude / Codex) behind a
/// native segmented control, bottom sheet with medium/large detents.
/// Codex shows a "coming soon" placeholder and cannot start a session,
/// but the tab stays selectable so users can always switch back.
struct RemoteNewSessionSheet: View {
    enum Tab: Int {
        case onDevice, claude, codex
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab
    @State private var claudeOptions: ClaudeSessionOptions

    private let onStart: (RemoteNewSessionResult) -> Void

    init(onStart: @escaping (RemoteNewSessionResult) -> Void) {
        self.onStart = onStart
        let saved = RemoteSessionDefaultsStore.load()
        // ① 项目路径默认预填：优先上次保存值；为空则取启用中远端实例最近一次
        // 连接报告的工作目录（桥广播 projectPath），避免首次必须手填。
        var prefillProjectPath = saved.projectPath
        if prefillProjectPath.isEmpty {
            let pstore = ProviderConfigStore.shared
            if let inst = pstore.instances.first(where: { $0.providerType == .remoteAgent && $0.isEnabled }) {
                prefillProjectPath = RemoteAgentConnection.load(instanceID: inst.id).projectPath
            }
        }
        _claudeOptions = State(initialValue: ClaudeSessionOptions(
            projectPath: prefillProjectPath,
            permissionMode: saved.permissionMode,
            executionMode: saved.executionMode,
            planMode: saved.planMode,
            model: saved.model,
            effort: saved.effort,
            sandboxMode: saved.sandboxMode,
            fallbackModel: saved.fallbackModel,
            forkSession: saved.forkSession,
            persistSession: saved.persistSession
        ))
        let initialTab: Tab
        switch saved.provider {
        case "codex": initialTab = .codex
        case "claude": initialTab = .claude
        default: initialTab = .onDevice
        }
        _tab = State(initialValue: initialTab)
    }

    private var canStart: Bool {
        switch tab {
        case .onDevice: true
        case .claude: true
        case .codex: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("On-Device").tag(Tab.onDevice)
                Text("Claude").tag(Tab.claude)
                Text("Codex").tag(Tab.codex)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().overlay(ClaudePalette.border)

            ScrollView {
                switch tab {
                case .onDevice: OnDevicePlaceholder()
                case .claude: RemoteClaudeOptionsForm(options: $claudeOptions)
                case .codex: CodexPlaceholder()
                }
            }

            Divider().overlay(ClaudePalette.border)

            bottomBar
        }
        .background(ClaudePalette.background)
        .onChange(of: claudeOptions) { saveClaudeDefaults($0) }
        .presentationDetents([.medium, .large])
    }

    private var startLabel: String {
        switch tab {
        case .onDevice: String(localized: "Start On-Device")
        case .claude: String(localized: "Start with Claude")
        case .codex: String(localized: "Start")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudePalette.textSecondary)
            }
            .buttonStyle(.plain)

            Button(action: start) {
                Text(startLabel)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .foregroundStyle(canStart ? ClaudePalette.ctaForeground : ClaudePalette.textSecondary)
            .background(Capsule().fill(canStart ? ClaudePalette.ctaBackground : ClaudePalette.border))
            .disabled(!canStart)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// ② 任何选项改动即持久化（关闭弹层/切 tab 也不丢，官方：saved after each start）。
    private func saveClaudeDefaults(_ opts: ClaudeSessionOptions) {
        RemoteSessionDefaultsStore.save(RemoteSessionDefaults(
            projectPath: opts.projectPath,
            provider: "claude",
            permissionMode: opts.permissionMode,
            executionMode: opts.executionMode,
            planMode: opts.planMode,
            model: opts.model,
            effort: opts.effort,
            fallbackModel: opts.fallbackModel,
            forkSession: opts.forkSession,
            persistSession: opts.persistSession,
            sandboxMode: opts.sandboxMode
        ))
    }

    private func start() {
        switch tab {
        case .onDevice:
            dismiss()
            onStart(.onDevice)
        case .claude:
            var opts = claudeOptions
            opts.projectPath = opts.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
            saveClaudeDefaults(opts)
            dismiss()
            onStart(.claude(opts))
        case .codex:
            break
        }
    }
}

/// On-device tab hero: the local agent needs no configuration.
private struct OnDevicePlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            emblem
            Text("On-Device Agent")
                .font(.title3.bold())
                .foregroundStyle(ClaudePalette.textPrimary)
            Text("Runs right on this phone. Zero setup, your data stays on-device.")
                .font(.subheadline)
                .foregroundStyle(ClaudePalette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
        .padding(.bottom, 24)
    }

    private var emblem: some View {
        Image(systemName: "iphone")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(ClaudePalette.textPrimary)
            .frame(width: 64, height: 64)
            .background(Circle().fill(ClaudePalette.cardFill))
    }
}

/// Codex tab placeholder: the bridge-side Codex path has not landed yet.
private struct CodexPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(ClaudePalette.textSecondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(ClaudePalette.cardFill))
            Text("Codex")
                .font(.title3.bold())
                .foregroundStyle(ClaudePalette.textPrimary)
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(ClaudePalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
        .padding(.bottom, 24)
    }
}


/// [Remote session options] In-chat options for a remote (Bridge) session,
/// shown from the chat top bar instead of the model picker: permission mode
/// and sandbox switch LIVE over the Bridge (`set_permission_mode` /
/// `set_sandbox_mode`); the model is fixed at session start (read-only).
/// When the session has not started yet (no live client) the selection is
/// persisted to the start defaults so the next start picks it up.
/// Visual language mirrors the official app's settings/model popups:
/// ivory page, borderless warm-gray cards, circular close button, centered
/// title, blue trailing checkmark on the selected row.
struct RemoteSessionOptionsSheet: View {
    let chatSessionID: String?
    let instanceID: String?
    let currentModelName: String?

    @Environment(\.dismiss) private var dismiss
    @State private var permissionMode: String
    @State private var sandboxMode: String
    @State private var applyError: String?

    private static let permissionOptions: [(value: String, title: String, detail: String)] = [
        ("default", "Default", "Ask before tools that need permission"),
        ("acceptEdits", "Accept Edits", "Auto-accept file edit tools"),
        ("plan", "Plan", "Read-only plan mode"),
        ("auto", "Auto", "Auto-approve routine tools"),
        ("bypassPermissions", "Bypass All", "Skip all permission prompts"),
    ]

    init(chatSessionID: String?, instanceID: String?, currentModelName: String?) {
        self.chatSessionID = chatSessionID
        self.instanceID = instanceID
        self.currentModelName = currentModelName
        let saved = RemoteSessionDefaultsStore.load()
        _permissionMode = State(initialValue: saved.permissionMode)
        _sandboxMode = State(initialValue: saved.sandboxMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top chrome: circular close button leading, title centered.
            ZStack {
                Text("Session Options")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClaudePalette.textPrimary)
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ClaudePalette.textPrimary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(ClaudePalette.cardFill))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Permission modes — the live control.
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Permission Mode")
                        VStack(spacing: 0) {
                            ForEach(Self.permissionOptions.indices, id: \.self) { idx in
                                let opt = Self.permissionOptions[idx]
                                optionRow(
                                    title: opt.title,
                                    detail: opt.detail,
                                    isSelected: permissionMode == opt.value
                                ) {
                                    selectPermission(opt.value)
                                }
                                if idx < Self.permissionOptions.count - 1 {
                                    rowDivider
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ClaudePalette.cardFill))
                    }

                    // Sandbox — live switch.
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Sandbox Mode")
                        VStack(spacing: 0) {
                            optionRow(title: "Standard", detail: "", isSelected: sandboxMode == "off") {
                                selectSandbox("off")
                            }
                            rowDivider
                            optionRow(title: "Sandbox (Safe Mode)", detail: "", isSelected: sandboxMode == "on") {
                                selectSandbox("on")
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ClaudePalette.cardFill))
                    }

                    // Model — fixed at session start (read-only).
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Model")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentModelName ?? String(localized: "Default"))
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(ClaudePalette.textPrimary)
                            Text("Model is fixed for this session")
                                .font(.caption)
                                .foregroundStyle(ClaudePalette.textSecondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ClaudePalette.cardFill))
                    }

                    Text("Applies immediately")
                        .font(.caption2)
                        .foregroundStyle(ClaudePalette.textSecondary)
                        .padding(.leading, 6)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(ClaudePalette.background)
        .presentationDetents([.medium, .large])
        .alert(
            "Couldn't apply the change",
            isPresented: Binding(
                get: { applyError != nil },
                set: { if !$0 { applyError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(applyError ?? "")
        }
    }

    // MARK: - Actions

    private func selectPermission(_ value: String) {
        guard value != permissionMode else { return }
        permissionMode = value
        persistDefaults()
        Task {
            await applyLive { try await $0.setPermissionMode(value) }
        }
    }

    private func selectSandbox(_ value: String) {
        guard value != sandboxMode else { return }
        sandboxMode = value
        persistDefaults()
        Task {
            await applyLive { try await $0.setSandboxMode(value) }
        }
    }

    /// Persist to the start defaults — the live switch (when a client
    /// exists) AND the next session start both read from here.
    private func persistDefaults() {
        var saved = RemoteSessionDefaultsStore.load()
        saved.permissionMode = permissionMode
        saved.sandboxMode = sandboxMode
        RemoteSessionDefaultsStore.save(saved)
    }

    private func applyLive(_ op: (CCPocketClient) async throws -> Void) async {
        guard let instanceID,
              let client = RemoteAgentStore.shared.existingClient(
                  instanceID: instanceID, chatSessionID: chatSessionID
              ) else {
            // Session not started — the defaults update above covers it.
            return
        }
        do {
            try await op(client)
        } catch {
            applyError = error.localizedDescription
        }
    }

    // MARK: - Building blocks

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(ClaudePalette.textSecondary)
            .padding(.leading, 6)
    }

    /// Selected row = blue trailing checkmark (official Select-model style).
    private func optionRow(title: String, detail: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedTitle(title))
                        .font(.system(size: 16))
                        .foregroundStyle(ClaudePalette.textPrimary)
                    if !detail.isEmpty {
                        Text(localizedTitle(detail))
                            .font(.caption)
                            .foregroundStyle(ClaudePalette.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ClaudePalette.selectionBlue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(ClaudePalette.border)
            .padding(.leading, 16)
    }

    private func localizedTitle(_ value: String) -> String {
        String(localized: String.LocalizationValue(value))
    }
}
