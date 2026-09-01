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

/// New-session sheet: three tabs (On-Device / Claude / Codex) behind a
/// native segmented control, bottom sheet with medium/large detents.
/// Codex is disabled until the bridge-side Codex path lands.
struct RemoteNewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var providerStore = ProviderConfigStore.shared

    @State private var tab: Int = 0
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
        _tab = State(initialValue: saved.provider == "codex" ? 2 : (saved.provider == "claude" ? 1 : 0))
    }

    private var canStart: Bool {
        switch tab {
        case 0: return true
        case 1: return !claudeOptions.projectPath.isEmpty
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Picker("", selection: $tab) {
                Text("On-Device").tag(0)
                Text("Claude").tag(1)
                Text("Codex").tag(2)
            }
            .pickerStyle(.segmented)
            .disabled(tab == 2)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                switch tab {
                case 0: onDeviceTab
                case 1: RemoteClaudeOptionsForm(options: $claudeOptions)
                default: codexTab
                }
            }

            Divider()

            // Bottom actions
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button {
                    start()
                } label: {
                    Text(startLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium, .large])
    }

    private var startLabel: String {
        switch tab {
        case 0: return "Start On-Device"
        case 1: return "Start with Claude"
        default: return "Start"
        }
    }

    private var onDeviceTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text("On-Device Agent")
                .font(.title3.bold())
            Text("Runs right on this phone. Zero setup, your data stays on-device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private var codexTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
                .padding(.top, 48)
            Text("Codex")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func start() {
        switch tab {
        case 0:
            dismiss()
            onStart(.onDevice)
        case 1:
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
        default:
            break
        }
    }
}
