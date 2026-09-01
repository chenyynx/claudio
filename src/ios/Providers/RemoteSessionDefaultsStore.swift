import Foundation

/// Persisted session-start defaults for the remote-agent new-session sheet
/// (official SessionStartDefaultsStore — per-provider key + last provider,
/// saved after each start, loaded before opening the sheet). Session-specific
/// values (worktree, maxTurns, maxBudgetUsd) are intentionally NOT persisted,
/// mirroring the official `sessionStartDefaultsToJson` exclusions: carrying
/// them over would create dangerous or stale defaults on the next session.
struct RemoteSessionDefaults: Codable, Equatable {
    var projectPath: String = ""
    var provider: String = "claude"
    var permissionMode: String = "default"
    var executionMode: String = "default"
    var planMode: Bool = false
    var model: String?
    var effort: String?
    var fallbackModel: String?
    var forkSession: Bool = false
    var persistSession: Bool = true
    var sandboxMode: String = "off"
}

/// UserDefaults persistence for [RemoteSessionDefaults].
enum RemoteSessionDefaultsStore {
    private static let claudeKey = "session_start_defaults_claude_v1"
    private static let lastProviderKey = "session_start_defaults_last_provider_v1"

    static func load() -> RemoteSessionDefaults {
        let provider = UserDefaults.standard.string(forKey: lastProviderKey) ?? "claude"
        let key = provider == "codex" ? "session_start_defaults_codex_v1" : claudeKey
        if let data = UserDefaults.standard.data(forKey: key),
           let defaults = try? JSONDecoder().decode(RemoteSessionDefaults.self, from: data) {
            return defaults
        }
        return RemoteSessionDefaults()
    }

    static func save(_ defaults: RemoteSessionDefaults) {
        let key = defaults.provider == "codex" ? "session_start_defaults_codex_v1" : claudeKey
        if let data = try? JSONEncoder().encode(defaults) {
            UserDefaults.standard.set(data, forKey: key)
        }
        UserDefaults.standard.set(defaults.provider, forKey: lastProviderKey)
    }
}
