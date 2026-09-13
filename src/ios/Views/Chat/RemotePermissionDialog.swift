import SwiftUI

/// [M3] Approval dialog for Bridge `permission_request` (remote agent).
/// Layout mirrors the local OffloadPermissionDialog exactly (same sheet
/// detents, icon, argument table, pinned bottom buttons) so both approval
/// flows read as one system. Answers via AIChatViewModel.respondToPermission
/// → CCPocketClient.sendPermissionResponse (approve / approve_always /
/// reject — official ApprovalBar semantics).
struct RemotePermissionDialogModifier: ViewModifier {
    @ObservedObject var vm: AIChatViewModel

    func body(content: Content) -> some View {
        // [隔离架构铁律 2026-09-09] sheet 的 item 迁到 RemoteAgentSessionState
        // （vm.remote.pendingPermission）。跨 ObservableObject 取 $ 投影不可行，
        // 且 ViewModifier 自身的 body 不会因 remote.objectWillChange 重算 ——
        // 必须由一个以 @ObservedObject 持有 remote 的子 View 承载 sheet，
        // 常驻观察（remote 随 VM 永在，无 nil-gate 重挂载；本地会话从不写入
        // → sheet 永不触发）。
        content
            .background(
                RemotePermissionSheetHost(vm: vm, remote: vm.remote)
            )
    }
}

/// Sheet 承载容器：@ObservedObject 观察 remote，保证 pendingPermission 变化
/// 时本 View 重算、sheet(item:) 正常弹出/关闭。
private struct RemotePermissionSheetHost: View {
    @ObservedObject var vm: AIChatViewModel
    @ObservedObject var remote: RemoteAgentSessionState

    var body: some View {
        Color.clear
            .sheet(item: Binding(
                get: { remote.pendingPermission },
                set: { remote.pendingPermission = $0 }
            )) { request in
                RemotePermissionDialogContent(request: request, vm: vm)
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled()
            }
    }
}

private struct RemotePermissionDialogContent: View {
    let request: RemotePermissionRequest
    @ObservedObject var vm: AIChatViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)

                        Text("Permission Request")
                            .font(.title3.bold())

                        Text("The agent wants to use **\(request.toolName)**")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Arguments (same key/value table as the local dialog)
                    if !request.input.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(request.input.keys.sorted()), id: \.self) { key in
                                HStack {
                                    Text(key)
                                        .font(.footnote.bold())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Text("\(request.input[key] ?? "")")
                                        .font(.footnote.monospaced())
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
            }

            // Buttons — pinned to the bottom of the sheet, outside the
            // ScrollView, so they stay tappable with long argument lists.
            VStack(spacing: 10) {
                Button {
                    vm.respondToPermission(request, allow: true)
                } label: {
                    Text("Allow in Session")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    vm.respondToPermission(request, allow: true, always: true)
                } label: {
                    Text("Always Allow")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button {
                    vm.respondToPermission(request, allow: false)
                } label: {
                    Text("Deny in Session")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }
}

extension View {
    /// [M3] Attach the remote-agent permission approval dialog.
    func remotePermissionDialog(vm: AIChatViewModel) -> some View {
        modifier(RemotePermissionDialogModifier(vm: vm))
    }
}

// MARK: - [AskDialog 2026-09-13] AskUserQuestion 作答弹窗（pending 态）

/// 问题弹窗挂载点。与审批弹窗同文件同构：pending 态不再画在聊天流里，
/// 改为 sheet 作答 —— 卡片高度在 占位→完整卡→摘要 之间剧变是"首次弹出被
/// 输入栏盖住 / 收场上下留白"的源头，弹窗不在 UICollectionView 里，无高度问题。
struct AskQuestionDialogModifier: ViewModifier {
    @ObservedObject var vm: AIChatViewModel

    func body(content: Content) -> some View {
        // [照抄 RemotePermissionDialog.swift:13-24 的既有教训] ViewModifier 自身
        // body 不会因 remote.objectWillChange 重算，sheet(item:) 必须由
        // @ObservedObject 持有 remote 的子 View 承载，否则永不触发。
        // 常驻挂载、无条件 gate —— 本地会话从不写 pendingAsk → 恒 nil → 永不弹。
        content
            .background(AskQuestionSheetHost(vm: vm, remote: vm.remote))
    }
}

/// Sheet 承载容器：观察 remote，pendingAsk 变化时重算、sheet 正常弹出/关闭。
private struct AskQuestionSheetHost: View {
    @ObservedObject var vm: AIChatViewModel
    @ObservedObject var remote: RemoteAgentSessionState

    var body: some View {
        Color.clear
            .sheet(item: Binding(
                get: { remote.pendingAsk },
                // [AskDialog] 刻意忽略写入：无关闭按钮 + interactiveDismissDisabled，
                // 出口只有「提交答案」「跳过」两条，都与流内卡片语义一致。
                // 若允许置 nil 收起，会留下一个 pending 死问题且再点不开。
                set: { _ in }
            )) { request in
                AskQuestionDialogContent(request: request, vm: vm)
                    .presentationDetents([.medium, .large])
                    // [AskDialog 审查修正] 不加 .presentationBackground(.clear)：
                    // AskQuestionCardView 自带 glassSurface(radius:24)，透明 sheet 底
                    // 会让一张玻璃卡孤零零浮在蒙层上。审批弹窗那侧是"内容层即玻璃"，
                    // 两侧不该各用一套做法 —— 保持 sheet 默认底，卡片玻璃在其上出效果。
                    .interactiveDismissDisabled()
            }
    }
}

private struct AskQuestionDialogContent: View {
    let request: PendingAskRequest
    @ObservedObject var vm: AIChatViewModel

    var body: some View {
        // 直接复用流内卡片本体：不新造视图、不叠第二套材质、submit/skip
        // 接既有 submitAskAnswer / skipAskAnswer ⇒ 答案编码零改动。
        AskQuestionCardView(
            payload: request.payload,
            status: .pending,
            block: block(),
            onSubmit: { answers in vm.submitAskAnswer(blockId: request.blockId, answers: answers) },
            onSkip: { vm.skipAskAnswer(blockId: request.blockId) }
        )
        .padding(16)
    }

    /// 卡片需要 block 来读写 askDraft（草稿存 Store 侧，弹窗关闭重开不丢）。
    /// 找不到时退回一次性空块：只影响草稿持久性，不会崩，也不写回任何状态。
    private func block() -> AssistantBlock {
        RemoteAgentSessionState.findBlock(in: vm.messages, byId: request.blockId)
            ?? AssistantBlock(kind: .questionCard, content: "", toolStatus: .running,
                              toolUseId: request.toolUseId)
    }
}

// MARK: - [AskDialog 2026-09-13] 流内紧凑行（pending 态留在聊天流里的那一行）

/// 替代原来的整张大卡：与工具胶囊同高（36pt），保住"这里问过什么"的上下文，
/// 点击重开弹窗。终态（answered/skipped/expired）不走这里，仍是摘要卡。
struct AskQuestionCompactRow: View {
    let payload: AskWirePayload
    let onReopen: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: AskPalette { .init(scheme: scheme) }

    var body: some View {
        Button(action: onReopen) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(payload.questions.first?.question ?? "Claude 提问")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if payload.questions.count > 1 {
                    Text("\(payload.questions.count) 题")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink3)
                }
                Text("点按作答")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink2)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36)
            .contentShape(Rectangle())
            .glassSurface(radius: 18, dark: scheme == .dark)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// [AskDialog 2026-09-13] 挂载远端问题作答弹窗。
    func askQuestionDialog(vm: AIChatViewModel) -> some View {
        modifier(AskQuestionDialogModifier(vm: vm))
    }
}

