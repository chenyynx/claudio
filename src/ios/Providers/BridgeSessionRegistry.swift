import Combine

/// One synced Bridge session entry (live broadcast or recent index).
/// `claudeId` is the provider session id — the resume key. Kept next to
/// the registry it feeds.
struct BridgeRemoteSessionEntry: Sendable, Equatable {
    var bridgeId: String?
    var claudeId: String
    var name: String?
    var preview: String?
    var projectPath: String?
    var updatedAt: Date?
    var isLive: Bool
}

/// Aggregates the Bridge's broadcast `session_list` payloads into one
/// observable source for the session-list UI. Every CCPocketClient reports
/// the session_list it receives (the Bridge broadcasts the same global
/// list to all connections); the registry keeps, per provider instance,
/// the set of Bridge session ids currently alive on that Bridge.
/// Sidebar remote rows read this for their green/grey running dot; Stop
/// Session flips it locally via markStopped before the next broadcast
/// confirms (idempotent: the broadcast replaces the whole set).
/// [Session sync] Additionally keeps a full remote-session inventory
/// (live broadcast entries + recent-sessions index) so the sidebar can
/// merge remote-only rows into the session list.
@MainActor
final class BridgeSessionRegistry: ObservableObject {
    static let shared = BridgeSessionRegistry()

    /// instanceID → Bridge session ids currently alive on that Bridge.
    @Published private(set) var activeBridgeIdsByInstance: [String: Set<String>] = [:]

    /// [Session sync] instanceID → merged remote-session inventory (live
    /// entries win over recent-index entries with the same claudeId).
    @Published private(set) var inventoryByInstance: [String: [BridgeRemoteSessionEntry]] = [:]

    private var liveByInstance: [String: [BridgeRemoteSessionEntry]] = [:]
    private var recentByInstance: [String: [BridgeRemoteSessionEntry]] = [:]

    private init() {}

    /// Replace the known live sessions for one instance with the freshest
    /// `session_list` payload received on any connection.
    func update(instanceID: String, sessions: [CCPocketProtocol.ServerSession]) {
        activeBridgeIdsByInstance[instanceID] = Set(sessions.compactMap { $0.id })
    }

    /// [Session sync] Replace the live subset of the inventory (broadcast).
    func setLive(instanceID: String, entries: [BridgeRemoteSessionEntry]) {
        liveByInstance[instanceID] = entries
        rebuildInventory(instanceID: instanceID)
    }

    /// [Session sync] Replace the recent subset of the inventory (index fetch).
    func setRecent(instanceID: String, entries: [BridgeRemoteSessionEntry]) {
        recentByInstance[instanceID] = entries
        rebuildInventory(instanceID: instanceID)
    }

    private func rebuildInventory(instanceID: String) {
        var merged: [String: BridgeRemoteSessionEntry] = [:]
        for entry in recentByInstance[instanceID] ?? [] {
            merged[entry.claudeId] = entry
        }
        for entry in liveByInstance[instanceID] ?? [] {
            merged[entry.claudeId] = entry
        }
        inventoryByInstance[instanceID] = merged.values.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    /// True when `bridgeId` is in the Bridge's current live-session list.
    func isActive(instanceID: String, bridgeId: String) -> Bool {
        activeBridgeIdsByInstance[instanceID]?.contains(bridgeId) ?? false
    }

    /// [Session sync] Liveness by Claude session id — synthetic rows have
    /// no persisted mapping, so they resolve liveness via the inventory.
    func isClaudeLive(instanceID: String, claudeId: String) -> Bool {
        inventoryByInstance[instanceID]?.contains {
            $0.claudeId == claudeId && $0.isLive
        } ?? false
    }

    /// [Session sync] The live Bridge id for a Claude session, if any —
    /// stored into the mapping when a synthetic row is materialized.
    func liveBridgeId(instanceID: String, claudeId: String) -> String? {
        inventoryByInstance[instanceID]?.first { $0.claudeId == claudeId }?.bridgeId
    }

    /// Optimistic local removal right after a Stop Session request — the
    /// next broadcast replaces the set anyway, so this only shortens the
    /// window where the row would still read green.
    func markStopped(instanceID: String, bridgeId: String) {
        activeBridgeIdsByInstance[instanceID]?.remove(bridgeId)
    }
}
