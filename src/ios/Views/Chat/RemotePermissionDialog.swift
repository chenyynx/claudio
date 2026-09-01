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
        content
            .sheet(item: $vm.pendingPermission) { request in
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
