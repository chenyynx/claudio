import SwiftUI

/// Standalone "Connect Your Computer" flow — the remote-agent (CC Pocket
/// Bridge) setup page, reached from the first-launch empty state. The same
/// QR-scan + manual-entry fields live inline in AddProviderView for users
/// who configure through the provider list; this page is the dedicated
/// entry point that makes the computer a first-class agent (peer of the
/// on-device steps, not a provider form).
struct RemoteAgentSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProviderConfigStore.shared

    /// When non-nil, this page edits the existing instance instead of
    /// adding a new one (fields prefilled, save updates in place).
    private let existingInstance: ProviderInstance?

    @State private var wssURL = ""
    @State private var token = ""
    @State private var projectPath = ""
    @State private var isSaving = false

    init(existingInstance: ProviderInstance? = nil) {
        self.existingInstance = existingInstance
        if let instance = existingInstance {
            _wssURL = State(initialValue: instance.customBaseURL ?? "")
            _token = State(initialValue: ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? "")
            _projectPath = State(initialValue: RemoteAgentConnection.load(instanceID: instance.id)?.projectPath ?? "")
        }
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedToken.isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section {
                Label(
                    "Scan the QR code printed by your Bridge Server, or paste the details below.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Label("On your computer, run:", systemImage: "terminal")
                HStack(spacing: 8) {
                    Text("npx --yes @ccpocket/bridge@latest")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = "npx --yes @ccpocket/bridge@latest"
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
                Label("The terminal shows a QR code. Scan it with the button below.", systemImage: "qrcode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Install the Bridge")
            }

            RemoteAgentConfigView(
                wssURL: $wssURL,
                token: $token,
                projectPath: $projectPath
            )

            Section("Bridge URL") {
                TextField("wss://your-computer:8766", text: $wssURL)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section("Token") {
                SecureField("Bridge token", text: $token)
                    .font(.system(.body, design: .monospaced))
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canSave)
            }
        }
        .navigationTitle("Connect Your Computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    /// Persist a `.remoteAgent` instance the same way AddProviderView's
    /// API-key path does: keychain token + RemoteAgentConnection path +
    /// store instance. Editing an existing instance updates it in place
    /// (same id, keychain, connection path) instead of adding a duplicate.
    /// After saving the empty-state section flips to its connected
    /// (checkmark) state on the next appearance.
    private func save() {
        let trimmedBase = wssURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }

        isSaving = true
        if let existing = existingInstance {
            var updated = existing
            updated.customBaseURL = trimmedBase.isEmpty ? nil : trimmedBase
            ProviderKeychainHelper.saveAPIKey(trimmedToken, instanceId: existing.id)
            RemoteAgentConnection.save(
                RemoteAgentConnection(projectPath: trimmedPath),
                instanceID: existing.id
            )
            store.updateInstance(updated)
        } else {
            let instance = ProviderInstance(
                label: ProviderType.remoteAgent.displayName,
                providerType: .remoteAgent,
                credentialType: .apiKey,
                customBaseURL: trimmedBase.isEmpty ? nil : trimmedBase,
                appendV1Suffix: false
            )
            ProviderKeychainHelper.saveAPIKey(trimmedToken, instanceId: instance.id)
            RemoteAgentConnection.save(
                RemoteAgentConnection(projectPath: trimmedPath),
                instanceID: instance.id
            )
            store.addInstance(instance)
        }
        isSaving = false
        dismiss()
    }
}
