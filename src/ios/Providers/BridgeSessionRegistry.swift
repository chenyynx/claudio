import Foundation

/// Aggregates the Bridge's broadcast `session_list` payloads into one
/// observable source for the session-list UI. Every CCPocketClient reports
/// the session_list it receives (the Bridge broadcasts the same global
/// list to all connections); the registry keeps, per provider instance,
/// the set of Bridge session ids currently alive on that Bridge.
/// Sidebar remote rows read this for their green/grey running dot; Stop
/// Session flips it locally via markStopped before the next broadcast
/// confirms (idempotent: the broadcast replaces the whole set).
@MainActor
final class BridgeSessionRegistry: ObservableObject {
    static let shared = BridgeSessionRegistry()

    /// instanceID → Bridge session ids currently alive on that Bridge.
    @Published private(set) var activeBridgeIdsByInstance: [String: Set<String>] = [:]

    private init() {}

    /// Replace the known live sessions for one instance with the freshest
    /// `session_list` payload received on any connection.
    func update(instanceID: String, sessions: [CCPocketProtocol.ServerSession]) {
        activeBridgeIdsByInstance[instanceID] = Set(sessions.compactMap { $0.id })
    }

    /// True when `bridgeId` is in the Bridge's current live-session list.
    func isActive(instanceID: String, bridgeId: String) -> Bool {
        activeBridgeIdsByInstance[instanceID]?.contains(bridgeId) ?? false
    }

    /// Optimistic local removal right after a Stop Session request — the
    /// next broadcast replaces the set anyway, so this only shortens the
    /// window where the row would still read green.
    func markStopped(instanceID: String, bridgeId: String) {
        activeBridgeIdsByInstance[instanceID]?.remove(bridgeId)
    }
}
