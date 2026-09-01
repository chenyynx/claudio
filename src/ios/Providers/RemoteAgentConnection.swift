import Foundation

/// Per-instance connection configuration for the remote agent (CC Pocket
/// Bridge). The wss URL and token live on ProviderInstance (customBaseURL /
/// keychain); the project path is stored here because ProviderInstance has
/// no field for it.
struct RemoteAgentConnection: Codable, Equatable {
    var projectPath: String
    /// Working directory suggestion shown in the config form.
    var provider: String = "claude"
    /// Bridge execution/permission mode for this connection. M1 defaults to
    /// bypassPermissions (no approval round-trips — the M1 client does not
    /// render permission requests yet); M3 adds an approval UI and exposes
    /// this as a user choice.
    var permissionMode: String = "bypassPermissions"

    // MARK: - Persistence

    private static func key(_ instanceID: String) -> String { "remoteAgent.connection.\(instanceID)" }

    static func load(instanceID: String) -> RemoteAgentConnection? {
        guard let data = UserDefaults.standard.data(forKey: key(instanceID)) else { return nil }
        return try? JSONDecoder().decode(RemoteAgentConnection.self, from: data)
    }

    static func save(_ connection: RemoteAgentConnection, instanceID: String) {
        if let data = try? JSONEncoder().encode(connection) {
            UserDefaults.standard.set(data, forKey: key(instanceID))
        }
    }

    static func clear(instanceID: String) {
        UserDefaults.standard.removeObject(forKey: key(instanceID))
    }
}

/// Holds live CCPocketClient connections per (ProviderInstance, chat
/// session) so that multi-turn chat reuses one Bridge session instead of
/// reconnecting (and losing context) on every message. [Per-session mapping]
/// Keyed per chat conversation: every conversation owns its Bridge session
/// (official: ChatSessionCubit holds its own sessionId); a second
/// conversation never reuses — let alone evicts — another one's connection.
final class RemoteAgentStore {

    static let shared = RemoteAgentStore()
    private var clients: [String: CCPocketClient] = [:]
    private let lock = NSLock()

    private init() {}

    private func storeKey(instanceID: String, chatSessionID: String?) -> String {
        instanceID + "." + (chatSessionID ?? "__detached__")
    }

    /// Existing live client for this (instance, chat session), if any.
    func existingClient(instanceID: String, chatSessionID: String?) -> CCPocketClient? {
        lock.lock()
        defer { lock.unlock() }
        return clients[storeKey(instanceID: instanceID, chatSessionID: chatSessionID)]
    }

    /// Keep a client for later reuse. Caller must have connected it.
    func retain(_ client: CCPocketClient, instanceID: String, chatSessionID: String?) {
        lock.lock()
        defer { lock.unlock() }
        let key = storeKey(instanceID: instanceID, chatSessionID: chatSessionID)
        clients[key]?.disconnect()
        clients[key] = client
    }

    /// Drop the cached connection (e.g. on settings change / disconnect).
    func release(instanceID: String, chatSessionID: String?) {
        lock.lock()
        defer { lock.unlock() }
        let key = storeKey(instanceID: instanceID, chatSessionID: chatSessionID)
        clients[key]?.disconnect()
        clients.removeValue(forKey: key)
    }

    /// All live client states, for the sidebar connection dot aggregation
    /// (any connected = connected; any connecting wins for the spinner).
    func liveStates() -> [CCPocketClient.State] {
        lock.lock()
        defer { lock.unlock() }
        return clients.values.map { $0.state }
    }
}
