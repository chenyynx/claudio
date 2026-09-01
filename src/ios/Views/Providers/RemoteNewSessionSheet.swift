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
/// stylesheet (2026-09-02): ivory-light #FAF9F5 (page background), slate-dark
/// #141413 (text + primary button), cloud-dark #87867F (secondary text),
/// borders slate @10%, and the app-level accent orange #D97757. Dark-mode
/// surfaces follow the Claude app (#262624 background / #30302E cards).
enum ClaudePalette {
    static let background = dynamic(0xFAF9F5, 0x262624)
    static let card = dynamic(0xFFFFFF, 0x30302E)
    static let textPrimary = dynamic(0x141413, 0xFAF9F5)
    static let textSecondary = dynamic(0x87867F, 0xB0AEA5)
    static let accent = Color(UIColor(hex: 0xD97757))
    static let ctaBackground = dynamic(0x141413, 0xFAF9F5)
    static let ctaForeground = dynamic(0xFAF9F5, 0x141413)

    static var border: Color {
        adaptive(0x141413, alpha: 0.1, darkHex: 0xFAF9F5, darkAlpha: 0.14)
    }

    static var iconMuted: Color {
        adaptive(0xD97757, alpha: 0.12, darkHex: 0xD97757, darkAlpha: 0.22)
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
        _claudeOptions = State(initialValue: ClaudeSessionOptions(
            projectPath: saved.projectPath,
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
        case .claude: !claudeOptions.projectPath.isEmpty
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
            .padding(.top, 6)
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
                    .foregroundStyle(ClaudePalette.textPrimary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(Capsule().strokeBorder(ClaudePalette.border, lineWidth: 1))
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

    private func start() {
        switch tab {
        case .onDevice:
            dismiss()
            onStart(.onDevice)
        case .claude:
            var opts = claudeOptions
            opts.projectPath = opts.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
            // Persist defaults (official: saved after each start).
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
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(ClaudePalette.accent)
            .frame(width: 64, height: 64)
            .background(Circle().fill(ClaudePalette.iconMuted))
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
                .background(Circle().fill(ClaudePalette.border))
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
