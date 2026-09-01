import SwiftUI

/// Claude (remote agent) options form inside the new-session sheet.
/// Rendered as plain cards — deliberately NOT a `Form`/`List`: the sheet
/// wraps tab content in a `ScrollView`, and a `List` nested inside a
/// `ScrollView` collapses to zero height (the blank-Claude-tab bug).
/// Field set and permission-mode linkage mirror the official
/// new_session_sheet.dart Claude tab; model list falls back to the
/// official defaults.
struct RemoteClaudeOptionsForm: View {
    @Binding var options: ClaudeSessionOptions

    fileprivate static let modelFallback: [String] = [
        "claude-opus-4-7", "claude-opus-4-7[1m]", "claude-opus-4-6",
        "claude-opus-4-6[1m]", "claude-opus-4-5-20251101",
        "claude-sonnet-4-6", "claude-haiku-4-6",
    ]
    fileprivate static let efforts = ["low", "medium", "high", "max"]

    fileprivate struct PermissionOption {
        let value: String
        let title: String
        let detail: String
    }

    fileprivate static let permissionOptions: [PermissionOption] = [
        .init(value: "default", title: "Default", detail: "Ask before tools that need permission"),
        .init(value: "acceptEdits", title: "Accept Edits", detail: "Auto-accept file edit tools"),
        .init(value: "plan", title: "Plan", detail: "Read-only plan mode"),
        .init(value: "auto", title: "Auto", detail: "Auto-approve routine tools"),
        .init(value: "bypassPermissions", title: "Bypass All", detail: "Skip all permission prompts"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            projectSection
            optionsSection
            worktreeSection
            advancedSection
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Sections

    private var projectSection: some View {
        card(header: "Project") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Project path", text: $options.projectPath)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(ClaudePalette.textPrimary)
                Text("Where the agent runs on your computer.")
                    .font(.caption)
                    .foregroundStyle(ClaudePalette.textSecondary)
            }
            .padding(14)
        }
    }

    private var optionsSection: some View {
        card(header: "Options") {
            Menu {
                ForEach(Self.permissionOptions, id: \.value) { opt in
                    Button {
                        selectPermission(opt.value)
                    } label: {
                        if options.permissionMode == opt.value {
                            Label(localized(opt.title), systemImage: "checkmark")
                        } else {
                            Text(localized(opt.title))
                        }
                    }
                }
            } label: {
                optionRow(
                    icon: "hand.raised",
                    title: "Permission Mode",
                    value: localized(Self.permissionOptions.first { $0.value == options.permissionMode }?.title ?? "Default"),
                    detail: Self.permissionOptions.first { $0.value == options.permissionMode }?.detail ?? ""
                )
            }

            rowDivider

            Menu {
                Button { options.sandboxMode = "off" } label: {
                    if options.sandboxMode == "off" { Label("Standard", systemImage: "checkmark") } else { Text("Standard") }
                }
                Button { options.sandboxMode = "on" } label: {
                    if options.sandboxMode == "on" { Label("Sandbox (Safe Mode)", systemImage: "checkmark") } else { Text("Sandbox (Safe Mode)") }
                }
            } label: {
                optionRow(
                    icon: "shield",
                    title: "Sandbox Mode",
                    value: options.sandboxMode == "on" ? "Sandbox (Safe Mode)" : "Standard",
                    detail: ""
                )
            }

            rowDivider

            Menu {
                ForEach(Self.modelFallback, id: \.self) { model in
                    Button {
                        options.model = model
                    } label: {
                        if options.model == model {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            } label: {
                optionRow(icon: "cpu", title: "Model", value: options.model ?? "Default", detail: "")
            }

            rowDivider

            Menu {
                ForEach(Self.efforts, id: \.self) { effort in
                    Button {
                        options.effort = effort
                    } label: {
                        if options.effort == effort {
                            Label(effort, systemImage: "checkmark")
                        } else {
                            Text(effort)
                        }
                    }
                }
            } label: {
                optionRow(icon: "gauge", title: "Effort", value: options.effort ?? "normal", detail: "")
            }
        }
    }

    private var worktreeSection: some View {
        card(header: "Worktree") {
            Toggle("Use Worktree", isOn: $options.useWorktree)
                .font(.system(size: 15))
                .foregroundStyle(ClaudePalette.textPrimary)
                .tint(ClaudePalette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if options.useWorktree {
                rowDivider
                TextField("Branch (optional)", text: Binding(
                    get: { options.worktreeBranch ?? "" },
                    set: { options.worktreeBranch = $0.isEmpty ? nil : $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(ClaudePalette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var advancedSection: some View {
        card(header: "Advanced") {
            TextField("Max turns (optional)", value: $options.maxTurns, format: .number)
                .font(.system(size: 15))
                .keyboardType(.numberPad)
                .foregroundStyle(ClaudePalette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            rowDivider

            TextField("Max budget USD (optional)", value: $options.maxBudgetUsd, format: .number)
                .font(.system(size: 15))
                .keyboardType(.decimalPad)
                .foregroundStyle(ClaudePalette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            rowDivider

            Menu {
                Button {
                    options.fallbackModel = nil
                } label: {
                    if options.fallbackModel == nil { Label("Default", systemImage: "checkmark") } else { Text("Default") }
                }
                ForEach(Self.modelFallback, id: \.self) { model in
                    Button {
                        options.fallbackModel = model
                    } label: {
                        if options.fallbackModel == model {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            } label: {
                optionRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Fallback Model",
                    value: options.fallbackModel ?? "Default",
                    detail: ""
                )
            }

            rowDivider

            Toggle("Fork Session", isOn: $options.forkSession)
                .font(.system(size: 15))
                .foregroundStyle(ClaudePalette.textPrimary)
                .tint(ClaudePalette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            rowDivider

            Toggle("Persist Session", isOn: $options.persistSession)
                .font(.system(size: 15))
                .foregroundStyle(ClaudePalette.textPrimary)
                .tint(ClaudePalette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(header: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(ClaudePalette.textSecondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 14).fill(ClaudePalette.card))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ClaudePalette.border, lineWidth: 1))
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(ClaudePalette.border)
            .padding(.leading, 56)
    }

    private func optionRow(icon: String, title: String, value: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ClaudePalette.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(ClaudePalette.iconMuted))
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(title))
                    .font(.system(size: 15))
                    .foregroundStyle(ClaudePalette.textPrimary)
                if !detail.isEmpty {
                    Text(localized(detail))
                        .font(.caption)
                        .foregroundStyle(ClaudePalette.textSecondary)
                }
            }
            Spacer()
            Text(localized(value))
                .font(.subheadline)
                .foregroundStyle(ClaudePalette.textSecondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ClaudePalette.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Logic

    /// Localize a dynamic string through the strings table (missing keys
    /// pass through unchanged, so model IDs / protocol values are safe).
    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value))
    }

    private func selectPermission(_ value: String) {
        options.permissionMode = value
        // Official linkage (new_session_sheet.dart 2656-2675).
        switch value {
        case "default", "auto":
            options.executionMode = "default"
            options.planMode = false
        case "acceptEdits":
            options.executionMode = "acceptEdits"
            options.planMode = false
        case "plan":
            options.planMode = true
        case "bypassPermissions":
            options.executionMode = "fullAccess"
            options.planMode = false
        default:
            break
        }
    }
}
