#if DEBUG
import Foundation

enum MockDoctorScenario: String, CaseIterable {
    case allPass = "all-pass"
    case freshInstall = "fresh-install"
    case noNode = "no-node"
    case noCli = "no-cli"
    case cliNoAuth = "cli-no-auth"
    case mixed = "mixed"

    var displayName: String {
        switch self {
        case .allPass: return "すべて合格"
        case .freshInstall: return "初回インストール"
        case .noNode: return "Node.js未インストール"
        case .noCli: return "CLI未インストール"
        case .cliNoAuth: return "CLI未認証"
        case .mixed: return "混合状態"
        }
    }

    func buildReport() -> DoctorReport {
        switch self {
        case .allPass:
            return Self.allPassReport()
        case .freshInstall:
            return Self.freshInstallReport()
        case .noNode:
            return Self.noNodeReport()
        case .noCli:
            return Self.noCliReport()
        case .cliNoAuth:
            return Self.cliNoAuthReport()
        case .mixed:
            return Self.mixedReport()
        }
    }

    // MARK: - Scenario Builders

    private static func allPassReport() -> DoctorReport {
        DoctorReport(
            results: [
                CheckResult(name: "Node.js", status: "pass", message: "v22.5.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "CLI providers", status: "pass", message: "1 provider authenticated", category: "required", remediation: nil, providers: [
                    ProviderResult(name: "Claude Code CLI", installed: true, version: "1.0.33", authenticated: true, authMessage: "Authenticated", remediation: nil),
                    ProviderResult(name: "Codex CLI", installed: true, version: "0.1.5", authenticated: true, authMessage: "Authenticated", remediation: nil),
                ]),
                CheckResult(name: "Bridge Server", status: "pass", message: "v0.7.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "launchd service", status: "pass", message: "Registered and running", category: "optional", remediation: nil, providers: nil),
            ],
            allRequiredPassed: true
        )
    }

    private static func freshInstallReport() -> DoctorReport {
        DoctorReport(
            results: [
                CheckResult(name: "Node.js", status: "fail", message: "Not found", category: "required", remediation: "Install Node.js via Homebrew: brew install node", providers: nil),
                CheckResult(name: "CLI providers", status: "fail", message: "No providers installed", category: "required", remediation: "Install a CLI provider", providers: [
                    ProviderResult(name: "Claude Code CLI", installed: false, version: nil, authenticated: false, authMessage: nil, remediation: "npm install -g @anthropic-ai/claude-code"),
                    ProviderResult(name: "Codex CLI", installed: false, version: nil, authenticated: false, authMessage: nil, remediation: "npm install -g @openai/codex"),
                ]),
                CheckResult(name: "Bridge Server", status: "fail", message: "Not installed", category: "required", remediation: "npm install -g @ccpocket/bridge", providers: nil),
                CheckResult(name: "launchd service", status: "skip", message: "Bridge not installed", category: "optional", remediation: "Set up Bridge as a launchd service", providers: nil),
            ],
            allRequiredPassed: false
        )
    }

    private static func noNodeReport() -> DoctorReport {
        DoctorReport(
            results: [
                CheckResult(name: "Node.js", status: "fail", message: "Not found", category: "required", remediation: "Install Node.js via Homebrew: brew install node", providers: nil),
                CheckResult(name: "CLI providers", status: "pass", message: "1 provider authenticated", category: "required", remediation: nil, providers: [
                    ProviderResult(name: "Claude Code CLI", installed: true, version: "1.0.33", authenticated: true, authMessage: "Authenticated", remediation: nil),
                ]),
                CheckResult(name: "Bridge Server", status: "pass", message: "v0.7.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "launchd service", status: "pass", message: "Registered and running", category: "optional", remediation: nil, providers: nil),
            ],
            allRequiredPassed: false
        )
    }

    private static func noCliReport() -> DoctorReport {
        DoctorReport(
            results: [
                CheckResult(name: "Node.js", status: "pass", message: "v22.5.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "CLI providers", status: "fail", message: "No providers installed", category: "required", remediation: "Install a CLI provider", providers: [
                    ProviderResult(name: "Claude Code CLI", installed: false, version: nil, authenticated: false, authMessage: nil, remediation: "npm install -g @anthropic-ai/claude-code"),
                    ProviderResult(name: "Codex CLI", installed: false, version: nil, authenticated: false, authMessage: nil, remediation: "npm install -g @openai/codex"),
                ]),
                CheckResult(name: "Bridge Server", status: "pass", message: "v0.7.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "launchd service", status: "pass", message: "Registered and running", category: "optional", remediation: nil, providers: nil),
            ],
            allRequiredPassed: false
        )
    }

    private static func cliNoAuthReport() -> DoctorReport {
        DoctorReport(
            results: [
                CheckResult(name: "Node.js", status: "pass", message: "v22.5.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "CLI providers", status: "warn", message: "Installed but not authenticated", category: "required", remediation: nil, providers: [
                    ProviderResult(name: "Claude Code CLI", installed: true, version: "1.0.33", authenticated: false, authMessage: "Not authenticated", remediation: "Run: claude login"),
                    ProviderResult(name: "Codex CLI", installed: true, version: "0.1.5", authenticated: false, authMessage: "Not authenticated", remediation: "Run: codex login"),
                ]),
                CheckResult(name: "Bridge Server", status: "pass", message: "v0.7.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "launchd service", status: "pass", message: "Registered and running", category: "optional", remediation: nil, providers: nil),
            ],
            allRequiredPassed: false
        )
    }

    private static func mixedReport() -> DoctorReport {
        DoctorReport(
            results: [
                CheckResult(name: "Node.js", status: "pass", message: "v22.5.0", category: "required", remediation: nil, providers: nil),
                CheckResult(name: "CLI providers", status: "pass", message: "1 provider authenticated", category: "required", remediation: nil, providers: [
                    ProviderResult(name: "Claude Code CLI", installed: true, version: "1.0.33", authenticated: true, authMessage: "Authenticated", remediation: nil),
                    ProviderResult(name: "Codex CLI", installed: false, version: nil, authenticated: false, authMessage: nil, remediation: "npm install -g @openai/codex"),
                ]),
                CheckResult(name: "Bridge Server", status: "fail", message: "Not installed", category: "required", remediation: "npm install -g @ccpocket/bridge", providers: nil),
                CheckResult(name: "launchd service", status: "warn", message: "Registered but not running", category: "optional", remediation: "Start the service: launchctl start com.ccpocket.bridge", providers: nil),
            ],
            allRequiredPassed: false
        )
    }
}
#endif
