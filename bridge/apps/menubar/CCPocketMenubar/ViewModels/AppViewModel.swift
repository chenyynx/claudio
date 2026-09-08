import Foundation
import SwiftUI
import ServiceManagement

enum BridgeStatus {
    case running
    case stopped
    case checking

    var label: String {
        switch self {
        case .running: return String(localized: "Running")
        case .stopped: return String(localized: "Stopped")
        case .checking: return String(localized: "Checking…")
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped: return .red
        case .checking: return .gray
        }
    }

    var icon: String {
        switch self {
        case .running: return "circle.fill"
        case .stopped: return "circle.fill"
        case .checking: return "circle.dotted"
        }
    }
}

enum AppTab: Int, CaseIterable, Identifiable {
    case usage = 0
    case qrCode = 1
    case doctor = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .usage: return String(localized: "Usage")
        case .qrCode: return String(localized: "Connect")
        case .doctor: return String(localized: "Doctor")
        }
    }

    var icon: String {
        switch self {
        case .usage: return "chart.bar"
        case .qrCode: return "qrcode"
        case .doctor: return "stethoscope"
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var bridgeStatus: BridgeStatus = .checking
    @Published var bridgeVersion: String?
    @Published var selectedTab: AppTab = .usage

    /// Set when a newer Bridge version is available on npm
    @Published var bridgeUpdateAvailable: String?

    /// Launch at Login state
    @Published var launchAtLogin: Bool = false {
        didSet {
            setLaunchAtLogin(launchAtLogin)
        }
    }

    /// Whether onboarding has been completed
    @Published var hasCompletedOnboarding: Bool

    private let bridgeClient = BridgeClient()
    private let processManager = BridgeProcessManager()

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        selectedTab = .qrCode
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    func toggleBridge() {
        Task {
            do {
                if bridgeStatus == .running {
                    try await processManager.stopService()
                    bridgeStatus = .stopped
                } else {
                    try await processManager.startService()
                    bridgeStatus = .checking
                    // Wait a bit for startup
                    try? await Task.sleep(for: .seconds(2))
                    checkHealth()
                }
            } catch {
                print("Bridge toggle failed: \(error)")
            }
        }
    }

    func checkHealth() {
        Task {
            let running = await bridgeClient.isRunning()
            bridgeStatus = running ? .running : .stopped

            if running {
                if let version = try? await bridgeClient.version() {
                    bridgeVersion = version.version
                    // Check for updates in background
                    checkForBridgeUpdate(currentVersion: version.version)
                }
            }
        }
    }

    // MARK: - Bridge Update Check

    private func checkForBridgeUpdate(currentVersion: String) {
        Task {
            guard let latest = await processManager.latestBridgeVersion() else { return }
            if latest != currentVersion {
                bridgeUpdateAvailable = latest
            } else {
                bridgeUpdateAvailable = nil
            }
        }
    }

    // MARK: - Launch at Login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set launch at login: \(error)")
        }
    }
}
