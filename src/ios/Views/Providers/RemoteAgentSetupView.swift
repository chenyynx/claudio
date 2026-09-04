import SwiftUI
import UIKit

/// Standalone "Connect Your Computer" flow — the remote-agent (CC Pocket
/// Bridge) setup page, reached from the first-launch empty state.
///
/// [Claude restyle 2026-09-05] Replaced the stock Form/Section layout with
/// an Apple-style hero + numbered-step layout. Visual language: warm ivory
/// background, monochrome char-coal CTA, monospace code blocks, hairline
/// dividers, sticky bottom action. Mirrors official app's "Connect Your
/// Computer" card visual but promotes it to a full setup page with clear
/// numbered steps (the original Form put everything in a flat list).
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
    @FocusState private var focused: Field?

    private enum Field { case url, token, path }

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
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection
                    Divider().overlay(ClaudePalette.border)
                    step1InstallSection
                    Divider().overlay(ClaudePalette.border)
                    step2ConnectSection
                    Divider().overlay(ClaudePalette.border)
                    step3PathSection
                    // Bottom padding to keep content above the sticky CTA
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 20)
            }
            .background(ClaudePalette.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)

            stickyConnectButton
        }
        .navigationTitle("Connect Your Computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(ClaudePalette.textPrimary)
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Brand mark — 80x80 circle with the desktop computer glyph,
            // charcoal fill matching the CTA so it reads as the page's
            // primary visual anchor (Apple Pay / Wallet style).
            ZStack {
                Circle()
                    .fill(ClaudePalette.ctaBackground)
                    .frame(width: 80, height: 80)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(ClaudePalette.ctaForeground)
            }
            .padding(.top, 24)
            .padding(.bottom, 8)

            Text("Connect Your Computer")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(ClaudePalette.textPrimary)

            Text("Run Claude Code on your computer, control it from this iPhone. The Bridge keeps them paired over a secure WebSocket.")
                .font(.subheadline)
                .foregroundStyle(ClaudePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 24)
    }

    // MARK: - Step 1 — Install the Bridge

    private var step1InstallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(number: 1, title: "Install the Bridge")

            Text("On your computer, paste this into a terminal:")
                .font(.subheadline)
                .foregroundStyle(ClaudePalette.textSecondary)

            // Monospace code block — charcoal-on-ivory, like a Notion / Figma
            // code card. Tappable rows in the card copy the snippet.
            codeBlock(
                text: "npx --yes @ccpocket/bridge@latest",
                onCopy: {
                    UIPasteboard.general.string = "npx --yes @ccpocket/bridge@latest"
                }
            )

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(ClaudePalette.textSecondary)
                Text("The terminal prints a QR code — scan it in step 2.")
                    .font(.caption)
                    .foregroundStyle(ClaudePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 24)
    }

    // MARK: - Step 2 — Scan or paste

    private var step2ConnectSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(number: 2, title: "Scan or paste details")

            // Primary action — Scan QR Code. Full-width charcoal CTA, the
            // fastest path for users who don't want to type.
            Button {
                NotificationCenter.default.post(name: .showRemoteQRScanner, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Scan QR Code")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(ClaudePalette.ctaForeground)
                .background(ClaudePalette.ctaBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            // Manual fallback — a quiet "or" then three hairline fields.
            // iOS 17+ field row style: floating label that doesn't jump
            // (placeholder only, focus reveals cursor). Matches the
            // /workspace backup/import form language.
            HStack(spacing: 8) {
                Rectangle().fill(ClaudePalette.border).frame(height: 0.5)
                Text("or paste manually")
                    .font(.caption)
                    .foregroundStyle(ClaudePalette.textSecondary)
                Rectangle().fill(ClaudePalette.border).frame(height: 0.5)
            }
            .padding(.top, 8)

            VStack(spacing: 18) {
                fieldRow(
                    label: "Bridge URL",
                    placeholder: "wss://your-computer:8766",
                    text: $wssURL,
                    field: .url,
                    monospace: true,
                    keyboard: .URL,
                    secure: false
                )
                fieldRow(
                    label: "Token",
                    placeholder: "Bridge token",
                    text: $token,
                    field: .token,
                    monospace: true,
                    keyboard: .default,
                    secure: true
                )
            }
        }
        .padding(.vertical, 24)
        .onReceive(NotificationCenter.default.publisher(for: .remoteQRScanResult)) { note in
            if let url = note.object as? String, let parsed = URLComponents(string: url), parsed.scheme?.hasPrefix("ws") == true {
                var base = parsed
                base.queryItems = nil
                base.fragment = nil
                if let s = base.string { wssURL = s }
                if let t = parsed.queryItems?.first(where: { $0.name == "token" })?.value {
                    token = t
                }
            }
        }
    }

    // MARK: - Step 3 — Project path

    private var step3PathSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(number: 3, title: "Pick a project")

            Text("The folder the agent runs in. Use the absolute path on your computer (e.g. /home/ubuntu/myapp).")
                .font(.subheadline)
                .foregroundStyle(ClaudePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            fieldRow(
                label: "Project Path",
                placeholder: "/path/to/project",
                text: $projectPath,
                field: .path,
                monospace: true,
                keyboard: .default,
                secure: false
            )
        }
        .padding(.vertical, 24)
    }

    // MARK: - Sticky CTA

    private var stickyConnectButton: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [ClaudePalette.background.opacity(0), ClaudePalette.background],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 24)

            Button {
                save()
            } label: {
                ZStack {
                    if isSaving {
                        ProgressView().tint(ClaudePalette.ctaForeground)
                    } else {
                        Text(canSave ? "Connect" : "Add a token to continue")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(ClaudePalette.ctaForeground)
                .background(
                    canSave
                        ? ClaudePalette.ctaBackground
                        : ClaudePalette.ctaBackground.opacity(0.35)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(ClaudePalette.background)
        }
    }

    // MARK: - Building blocks

    /// "① Install the Bridge" — small circled number (charcoal filled when
    /// active) + semibold title. Mirrors the empty-state `setupStep` glyph.
    @ViewBuilder
    private func stepHeader(number: Int, title: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(ClaudePalette.ctaBackground)
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(ClaudePalette.ctaForeground)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(ClaudePalette.textPrimary)
            Spacer()
        }
    }

    /// Monospace code card — ivory fill, hairline border, copy button at
    /// the trailing edge. Tappable to copy the snippet.
    @ViewBuilder
    private func codeBlock(text: String, onCopy: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(ClaudePalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ClaudePalette.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ClaudePalette.cardFill)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ClaudePalette.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// One form row: small uppercase label above an underline-only text
    /// field. The label never moves (Apple/Linear style); the field uses
    /// native iOS focus underline. Switches to SecureField for tokens.
    @ViewBuilder
    private func fieldRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        monospace: Bool,
        keyboard: UIKeyboardType,
        secure: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(ClaudePalette.textSecondary)
                .tracking(0.4)

            Group {
                if secure {
                    SecureField(placeholder, text: text)
                        .textContentType(.oneTimeCode)
                } else {
                    TextField(placeholder, text: text)
                        .keyboardType(keyboard)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .focused($focused, equals: field)
            .font(monospace ? .system(.body, design: .monospaced) : .body)
            .foregroundStyle(ClaudePalette.textPrimary)

            Rectangle()
                .fill(focused == field ? ClaudePalette.ctaBackground : ClaudePalette.border)
                .frame(height: focused == field ? 1.5 : 0.5)
                .animation(.easeInOut(duration: 0.15), value: focused)
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

extension Notification.Name {
    static let showRemoteQRScanner = Notification.Name("showRemoteQRScanner")
    static let remoteQRScanResult = Notification.Name("remoteQRScanResult")
}
