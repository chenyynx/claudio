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
    /// [Model catalog] 桥在 session_list 广播里送来的模型目录,
    /// 远端连接时为空 → 走 fallback。
    @ObservedObject private var catalog = RemoteModelCatalog.shared

    fileprivate static let modelFallback: [String] = [
        "claude-opus-4-7", "claude-opus-4-7[1m]", "claude-opus-4-6",
        "claude-opus-4-6[1m]", "claude-opus-4-5-20251101",
        "claude-sonnet-4-6", "claude-haiku-4-6",
    ]
    fileprivate static let efforts = ["low", "medium", "high", "max"]

    /// 当前可用的 Claude 模型列表(桥送来的 + fallback 兜底)
    private var availableModels: [String] {
        let live = catalog.claudeModels()
        return live.isEmpty ? Self.modelFallback : live
    }

    /// 当前选中 model 的 effort 档位(桥送来的);空 = 该 model 不支持
    private var currentModelEfforts: [String] {
        catalog.claudeModelEfforts(for: options.model)
    }

    /// model 是否支持 effort(用于 UI 决定显示 chip vs "不支持"提示)
    private var currentModelSupportsEffort: Bool {
        catalog.supportsEffort(model: options.model)
    }

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
                    title: "Sandbox Mode",
                    value: options.sandboxMode == "on" ? "Sandbox (Safe Mode)" : "Standard",
                    detail: ""
                )
            }

            rowDivider

            Menu {
                ForEach(availableModels, id: \.self) { model in
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
                optionRow(title: "Model", value: options.model ?? "Default", detail: "")
            }

            rowDivider

            // [Model catalog] Effort 联动 chip 区。
            // 当前 model 不支持 effort (如 haiku):显示提示行。
            // 支持:渲染 chip 行(选中态 = cta 黑底白字)。
            if !currentModelSupportsEffort {
                optionRow(
                    title: "Effort",
                    value: localized("Not supported"),
                    detail: localized("This model does not support effort levels")
                )
            } else {
                effortChipSection
            }
        }
    }

    private var worktreeSection: some View {
        card(header: "Worktree") {
            Toggle("Use Worktree", isOn: $options.useWorktree)
                .font(.system(size: 15))
                .foregroundStyle(ClaudePalette.textPrimary)
                .tint(ClaudePalette.selectionBlue)
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

    /// [Model catalog] Effort chip 联动区。
    /// 当前 model 支持 effort 时渲染一行可点 chip;选中态 = 黑底白字,
    /// 未选中态 = 浅灰底深字。点 chip 写回 options.effort。
    /// 空数组(haiku 等)由调用方 optionRow 走"Not supported"分支,
    /// 这里不做二次判断。
    private var effortChipSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localized("Effort"))
                    .font(.system(size: 15))
                    .foregroundStyle(ClaudePalette.textPrimary)
                Spacer()
                if let cur = options.effort {
                    Text(cur.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(ClaudePalette.textSecondary)
                } else {
                    Text(localized("Default"))
                        .font(.subheadline)
                        .foregroundStyle(ClaudePalette.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "Default" chip — clear effort
                    effortChip(label: localized("Default"),
                               selected: options.effort == nil) {
                        options.effort = nil
                    }
                    ForEach(currentModelEfforts, id: \.self) { level in
                        effortChip(label: level.capitalized,
                                   selected: options.effort == level) {
                            options.effort = level
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    /// 单个 chip 视图(选中态用 cta 配色,未选中态用 card 配色 + 浅边框)
    @ViewBuilder
    private func effortChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? ClaudePalette.ctaForeground : ClaudePalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(selected ? AnyShapeStyle(ClaudePalette.ctaBackground)
                                       : AnyShapeStyle(ClaudePalette.cardFill))
                )
                .overlay(
                    Capsule()
                        .stroke(selected ? Color.clear : ClaudePalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
                ForEach(availableModels, id: \.self) { model in
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
                    title: "Fallback Model",
                    value: options.fallbackModel ?? "Default",
                    detail: ""
                )
            }

            rowDivider

            Toggle("Fork Session", isOn: $options.forkSession)
                .font(.system(size: 15))
                .foregroundStyle(ClaudePalette.textPrimary)
                .tint(ClaudePalette.selectionBlue)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            rowDivider

            Toggle("Persist Session", isOn: $options.persistSession)
                .font(.system(size: 15))
                .foregroundStyle(ClaudePalette.textPrimary)
                .tint(ClaudePalette.selectionBlue)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(header: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.subheadline)
                .foregroundStyle(ClaudePalette.textSecondary)
                .padding(.leading, 6)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ClaudePalette.cardFill))
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(ClaudePalette.border)
            .padding(.leading, 16)
    }

    private func optionRow(title: String, value: String, detail: String) -> some View {
        HStack(spacing: 12) {
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
