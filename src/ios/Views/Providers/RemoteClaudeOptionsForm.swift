import SwiftUI

/// Claude (remote agent) options form inside the new-session sheet.
/// Field set and permission-mode linkage mirror the official
/// new_session_sheet.dart Claude tab: permission mode drives execution
/// mode / plan mode, model list falls back to the official defaults.
struct RemoteClaudeOptionsForm: View {
    @Binding var options: ClaudeSessionOptions

    private static let modelFallback: [String] = [
        "claude-opus-4-7", "claude-opus-4-7[1m]", "claude-opus-4-6",
        "claude-opus-4-6[1m]", "claude-opus-4-5-20251101",
        "claude-sonnet-4-6", "claude-haiku-4-6",
    ]
    private static let efforts = ["low", "medium", "high", "max"]

    private struct PermissionOption {
        let value: String
        let title: String
        let detail: String
    }

    private static let permissionOptions: [PermissionOption] = [
        .init(value: "default", title: "Default", detail: "Ask before tools that need permission"),
        .init(value: "acceptEdits", title: "Accept Edits", detail: "Auto-accept file edit tools"),
        .init(value: "plan", title: "Plan", detail: "Read-only plan mode"),
        .init(value: "auto", title: "Auto", detail: "Auto-approve routine tools"),
        .init(value: "bypassPermissions", title: "Bypass All", detail: "Skip all permission prompts"),
    ]

    var body: some View {
        Form {
            Section {
                TextField("Project path", text: $options.projectPath)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("Where the agent runs on your computer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Project")
            }

            Section {
                Menu {
                    ForEach(Self.permissionOptions, id: \.value) { opt in
                        Button {
                            selectPermission(opt.value)
                        } label: {
                            if options.permissionMode == opt.value {
                                Label(opt.title, systemImage: "checkmark")
                            } else {
                                Text(opt.title)
                            }
                        }
                    }
                } label: {
                    optionRow(
                        icon: "hand.raised",
                        title: "Permission Mode",
                        value: Self.permissionOptions.first { $0.value == options.permissionMode }?.title ?? "Default",
                        detail: Self.permissionOptions.first { $0.value == options.permissionMode }?.detail ?? ""
                    )
                }

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
                    optionRow(
                        icon: "cpu",
                        title: "Model",
                        value: options.model ?? "Default",
                        detail: ""
                    )
                }

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
                    optionRow(
                        icon: "gauge",
                        title: "Effort",
                        value: options.effort ?? "normal",
                        detail: ""
                    )
                }
            } header: {
                Text("Options")
            }

            Section {
                Toggle("Use Worktree", isOn: $options.useWorktree)
                if options.useWorktree {
                    TextField("Branch (optional)", text: Binding(
                        get: { options.worktreeBranch ?? "" },
                        set: { options.worktreeBranch = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Worktree")
            }

            Section {
                TextField("Max turns (optional)", value: $options.maxTurns, format: .number)
                    .keyboardType(.numberPad)
                TextField("Max budget USD (optional)", value: $options.maxBudgetUsd, format: .number)
                    .keyboardType(.decimalPad)
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
                Toggle("Fork Session", isOn: $options.forkSession)
                Toggle("Persist Session", isOn: $options.persistSession)
            } header: {
                Text("Advanced")
            }
        }
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

    private func optionRow(icon: String, title: String, value: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
