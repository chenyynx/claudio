import SwiftUI

/// Navigation-bar connection dot for the remote-agent (Bridge) provider.
/// Green = a live client is connected; spinner = connecting; grey = not
/// configured yet or no live connection. Tap is delegated to the caller
/// (the toolbar principal item rebuilds often, so the sheet state must
/// live on the stable ContentView, not here).
struct ConnectionStatusDot: View {
    let onTap: () -> Void

    @ObservedObject private var connectionStore = ConnectionStatusStore.shared

    private var accessibilityText: String {
        switch connectionStore.status {
        case .connecting: return String(localized: "Connecting to your computer")
        case .connected: return String(localized: "Connected to your computer")
        case .notConfigured: return String(localized: "Your computer is not set up")
        case .disconnected: return String(localized: "Disconnected from your computer")
        }
    }

    var body: some View {
        Button(action: onTap) {
            // Cloud glyph (not a bare dot) — matches the ☁ remote-session
            // badge language in the session list: filled = connected,
            // outline = no live connection.
            Group {
                switch connectionStore.status {
                case .connecting:
                    ProgressView()
                        .controlSize(.mini)
                case .connected:
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(UIColor.systemGreen))
                case .notConfigured, .disconnected:
                    Image(systemName: "cloud")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(UIColor.systemGray3))
                }
            }
            .frame(width: 44, height: 44)
            // 44pt minimum tap target around the 10pt dot.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }
}
