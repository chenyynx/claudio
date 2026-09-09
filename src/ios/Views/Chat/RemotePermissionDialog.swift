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
