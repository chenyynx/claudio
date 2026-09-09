import SwiftUI

/// Onboarding step 2: pick one or more models from all configured providers and create a "Default Models" group.
struct OnboardingModelSelectionView: View {
    @ObservedObject private var store = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    /// [Fix 2026-09-09] push 模式（AddProviderView 保存后推入）传 false：
    /// 左上角由系统返回键承担"回添加页改配置"，不再显示 Skip。
    /// sheet 独立入口（欢迎页卡片"补第②步"）保持默认 true。
    var showsSkipButton: Bool = true
    /// [Fix 2026-09-09] 选完模型建组后的收尾。push 模式由调用方传 sheet
    /// 的 dismiss（关整个流程）；sheet 独立入口传 nil → 走环境 dismiss。
    var onFinished: (() -> Void)? = nil

    @State private var selectedModelEntryIds: [String] = []
    @State private var searchText: String = ""
    // [Fix 2026-09-09] 页面自治拉取状态。此前本页只读 store、从不拉取：
    // AddProviderView 保存时的 fire-and-forget 拉取一旦失败/悬挂（网络、key、
    // baseURL 问题），entries 恒空 → 本页永远显示假 "Loading models..."，
    // 无错误态无重试（官方同款缺陷）。
    @State private var isFetching = false
    @State private var fetchError: String? = nil
    @State private var loadAttempted = false

    /// All visible model entries across all enabled LOCAL instances.
    /// [Fix 2026-09-09] 远端 agent 不进本地选模型流程 —— 它有独立入口
    /// （设置 → 远程 / 欢迎页卡片），模型由桥端目录在远端会话里选。
    private var allEntries: [ModelEntry] {
        store.instances
            .filter { $0.isEnabled && $0.providerType != .remoteAgent }
            .flatMap { store.visibleEntries(for: $0.id) }
    }

    var body: some View {
        List {
            if allEntries.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            if isFetching {
                                ProgressView()
                                Text("Loading models...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let err = fetchError {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Retry") {
                                    loadAttempted = false
                                    Task { await loadModelsIfNeeded() }
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Text("No models found for this provider. Check the base URL and API key, then retry.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Retry") {
                                    loadAttempted = false
                                    Task { await loadModelsIfNeeded() }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Models")
                } footer: {
                    Text(isFetching ? "Fetching model list from your provider…" : "Tap retry to fetch again, or Skip to configure later.")
                }
            } else {
                // Group entries by provider instance
                let instanceIds = store.instances
                    .filter { $0.isEnabled && $0.providerType != .remoteAgent }
                    .map(\.id)
                ForEach(instanceIds, id: \.self) { instanceId in
                    let entries = store.visibleEntries(for: instanceId).filter { entry in
                        searchText.isEmpty || entry.model.displayName.localizedCaseInsensitiveContains(searchText)
                    }
                    if !entries.isEmpty, let instance = store.instance(for: instanceId) {
                        Section {
                            ForEach(entries) { entry in
                                modelRow(entry: entry)
                            }
                        } header: {
                            Text(instance.label)
                        }
                    }
                }

            }
        }
        .task { await loadModelsIfNeeded() }
        .searchable(text: $searchText, prompt: "Filter models")
        .navigationTitle("Select Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsSkipButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next") { createGroupAndDismiss() }
                    .disabled(selectedModelEntryIds.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func modelRow(entry: ModelEntry) -> some View {
        let selectionIndex = selectedModelEntryIds.firstIndex(of: entry.id)
        let isSelected = selectionIndex != nil

        Button {
            if let idx = selectionIndex {
                selectedModelEntryIds.remove(at: idx)
            } else {
                selectedModelEntryIds.append(entry.id)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color(UIColor.tertiarySystemFill))
                        .frame(width: 26, height: 26)
                    if isSelected, let idx = selectionIndex {
                        Text("\(idx + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                Text(entry.model.displayName)
                    .font(.body)
                    .foregroundStyle(Color(UIColor.label))
                Spacer()
            }
        }
    }

    /// [Fix 2026-09-09] 进入页面时对 entries 为空的本地实例主动拉一次
    /// （fetchModelsWithFallback，与 ProviderInstanceDetailView.refreshModels
    /// 同款调用 + 同款 replaceEntries 写回）。逐实例串行避免并发打 API；
    /// 全部失败时聚合首条错误到错误态。remoteAgent 实例不进本流程（隔离）。
    private func loadModelsIfNeeded() async {
        guard !loadAttempted, allEntries.isEmpty else { return }
        loadAttempted = true
        let targets = store.instances.filter { inst in
            inst.isEnabled && inst.providerType != .remoteAgent
                && store.visibleEntries(for: inst.id).isEmpty
        }
        guard !targets.isEmpty else { return }
        isFetching = true
        fetchError = nil
        var firstError: String?
        for inst in targets {
            do {
                let result = try await ProviderConfigStore.fetchModelsWithFallback(inst, forceRefresh: true)
                store.replaceEntries(for: inst.id, models: result.models)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        isFetching = false
        if allEntries.isEmpty, let err = firstError {
            fetchError = err
        }
    }

    private func createGroupAndDismiss() {
        // [Fix 2026-09-09] 防二次分组：本页建组语义只属于首次 onboarding
        // （默认组不存在）。已配置用户（返回修改后重新选模型 / 其他再入）
        // 把新选模型并入现有默认组，不新建组。
        if let existingId = store.defaultPrimaryGroupId,
           let existing = store.modelGroups.first(where: { $0.id == existingId }) {
            var updated = existing
            updated.memberEntryIds = Array(Set(existing.memberEntryIds).union(selectedModelEntryIds))
            store.updateGroup(updated)
        } else {
            let group = ModelGroup(
                name: "Default Models",
                memberEntryIds: selectedModelEntryIds,
                strategy: .fallback
            )
            store.addGroup(group)
            store.defaultPrimaryGroupId = group.id
        }
        if let finish = onFinished {
            finish()
        } else {
            dismiss()
        }
    }
}
