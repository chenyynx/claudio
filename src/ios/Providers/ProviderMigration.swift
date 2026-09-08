import Foundation
import Security
import os.log

private let logger = AppLogger(category: "ProviderMigration")

/// Migrates existing provider configuration (AuthMode, API keys, OAuth state)
/// into the new ProviderInstance / ModelEntry / ModelGroup system.
@MainActor
enum ProviderMigration {

    private static let migrationKey = "com.claudio.app.provider-migration-v1-done"
    private static let oauthMigrationKey = "com.claudio.app.provider-migration-oauth-v2-done"
    /// [Fix 2026-09-09] 远端 entry 从本地模型组摘除（一次性）。
    private static let remoteGroupIsolationKey = "com.claudio.app.provider-migration-remote-group-isolation-v3-done"

    /// Run migration if it hasn't been performed yet.
    static func migrateIfNeeded(store: ProviderConfigStore) {
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            logger.info("Starting provider migration from legacy config")
            migrate(store: store)
            UserDefaults.standard.set(true, forKey: migrationKey)
            logger.info("Provider migration complete")
        }

        if !UserDefaults.standard.bool(forKey: oauthMigrationKey) {
            migrateOAuthTokens(store: store)
            UserDefaults.standard.set(true, forKey: oauthMigrationKey)
        }

        if !UserDefaults.standard.bool(forKey: remoteGroupIsolationKey) {
            migrateRemoteEntriesOutOfGroups(store: store)
            UserDefaults.standard.set(true, forKey: remoteGroupIsolationKey)
        }
    }

    // MARK: - V3: 远端 agent 的 entry 从本地模型组里摘掉

    /// [Fix 2026-09-09] 远端 agent（My Computer）不是本地服务商：没有 API key、
    /// 模型由桥端目录提供，且管理入口独立（设置 → 远程 / 欢迎页卡片）。但历史
    /// 数据里模型组可能混进了远端 entry（本地选择器曾把它们列出来）。组解析有
    /// hasAnyCredential 门槛（remoteAgent 恒 false）所以不会真被调用，但 UI 上
    /// 是串台。这里一次性摘掉；组本身与其余成员、组顺序都不动（空组保留，用户
    /// 可能还要往里加本地模型）。
    private static func migrateRemoteEntriesOutOfGroups(store: ProviderConfigStore) {
        let remoteEntryIds = Set(store.modelEntries.compactMap { entry -> String? in
            let instance = store.instance(for: entry.providerInstanceId)
            return instance?.providerType == .remoteAgent ? entry.id : nil
        })
        guard !remoteEntryIds.isEmpty else { return }

        var touchedGroups = 0
        var removedMembers = 0
        for group in store.modelGroups {
            let kept = group.memberEntryIds.filter { !remoteEntryIds.contains($0) }
            guard kept.count != group.memberEntryIds.count else { continue }
            var updated = group
            updated.memberEntryIds = kept
            store.updateGroup(updated)
            touchedGroups += 1
            removedMembers += group.memberEntryIds.count - kept.count
        }
        logger.info("Remote-entry group isolation: removed \(removedMembers) member(s) across \(touchedGroups) group(s)")
    }

    // MARK: - V2: Migrate singleton OAuth tokens → per-instance storage

    private static func migrateOAuthTokens(store: ProviderConfigStore) {
        logger.info("Starting OAuth token migration to per-instance storage")

        for instance in store.instances where instance.credentialType == .oauth {
            switch instance.providerType {
            case .anthropic:
                // Skip if per-instance token already exists
                if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: ClaudeTokenStorage.self) != nil {
                    continue
                }
                if let token = ClaudeOAuthManager.loadLegacyToken() {
                    ProviderKeychainHelper.saveOAuthToken(token, instanceId: instance.id)
                    ClaudeOAuthManager.deleteLegacyToken()
                    logger.info("Migrated Claude OAuth token to instance \(instance.id)")
                }

            case .gemini:
                if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: GeminiTokenStorage.self) != nil {
                    continue
                }
                if let token = GeminiOAuthManager.loadLegacyToken() {
                    ProviderKeychainHelper.saveOAuthToken(token, instanceId: instance.id)
                    GeminiOAuthManager.deleteLegacyToken()
                    logger.info("Migrated Gemini OAuth token to instance \(instance.id)")
                }
                // Migrate email and project ID from UserDefaults
                if let email = UserDefaults.standard.string(forKey: GeminiOAuthManager.legacyEmailKey) {
                    ProviderKeychainHelper.saveOAuthString(email, instanceId: instance.id, account: "oauth-email")
                    UserDefaults.standard.removeObject(forKey: GeminiOAuthManager.legacyEmailKey)
                }
                if let projectID = UserDefaults.standard.string(forKey: GeminiOAuthManager.legacyProjectIDKey) {
                    ProviderKeychainHelper.saveOAuthString(projectID, instanceId: instance.id, account: "oauth-gcp-project")
                    UserDefaults.standard.removeObject(forKey: GeminiOAuthManager.legacyProjectIDKey)
                }

            case .openAI:
                if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: CodexTokenStorage.self) != nil {
                    continue
                }
                if let token = CodexOAuthManager.loadLegacyToken() {
                    ProviderKeychainHelper.saveOAuthToken(token, instanceId: instance.id)
                    CodexOAuthManager.deleteLegacyToken()
                    logger.info("Migrated Codex OAuth token to instance \(instance.id)")
                }

            case .antigravity:
                // No legacy tokens to migrate for Antigravity (new provider)
                break
            case .remoteAgent:
                // API-key only (Bridge token); no OAuth migration.
                break
            case .openRouter:
                // No legacy tokens to migrate for OpenRouter (new provider)
                break
            case .openAIResponses:
                break
            case .xAI:
                // xAI is a new provider; no legacy singleton tokens to migrate.
                break
            case .kimiCode:
                // Kimi is a new provider; no legacy singleton tokens to migrate.
                break
            case .unsupported:
                break
            }
        }

        logger.info("OAuth token migration complete")
    }

    // MARK: - V1: Legacy migration

    private static func migrate(store: ProviderConfigStore) {
        var config = ProviderConfig.empty
        var firstGroupEntryIds: [String] = []

        // MARK: - Anthropic

        // API Key
        if let key = readLegacyKeychain(service: "com.claudio.app.anthropic-api-key") {
            let instance = ProviderInstance(
                label: "Anthropic API Key",
                providerType: .anthropic,
                credentialType: .apiKey
            )
            config.instances.append(instance)
            let entries = LLMModel.allAnthropic.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)
            // Save key to new keychain location
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)

            if isLegacyActiveProvider("API Key") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // OAuth — check legacy singleton keychain directly
        if ClaudeOAuthManager.loadLegacyToken() != nil {
            let instance = ProviderInstance(
                label: "Claude OAuth",
                providerType: .anthropic,
                credentialType: .oauth
            )
            config.instances.append(instance)
            let entries = LLMModel.allAnthropic.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)

            if isLegacyActiveProvider("OAuth") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // MARK: - Gemini

        // API Key
        if let key = readLegacyKeychain(service: "com.claudio.app.gemini-api-key") {
            let instance = ProviderInstance(
                label: "Gemini API Key",
                providerType: .gemini,
                credentialType: .apiKey
            )
            config.instances.append(instance)
            let entries = LLMModel.allGemini.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)

            if isLegacyActiveProvider("Gemini API Key") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // OAuth
        if GeminiOAuthManager.loadLegacyToken() != nil {
            let instance = ProviderInstance(
                label: "Gemini OAuth",
                providerType: .gemini,
                credentialType: .oauth
            )
            config.instances.append(instance)
            let entries = LLMModel.allGemini.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)

            if isLegacyActiveProvider("Gemini OAuth") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // MARK: - OpenAI

        // API Key
        if let key = readLegacyKeychain(service: "com.claudio.app.openai-api-key") {
            let instance = ProviderInstance(
                label: "OpenAI API Key",
                providerType: .openAI,
                credentialType: .apiKey
            )
            config.instances.append(instance)
            let entries = LLMModel.allOpenAI.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)

            if isLegacyActiveProvider("OpenAI API Key") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // Codex OAuth
        if CodexOAuthManager.loadLegacyToken() != nil {
            let instance = ProviderInstance(
                label: "Codex OAuth",
                providerType: .openAI,
                credentialType: .oauth
            )
            config.instances.append(instance)
            let entries = LLMModel.allOpenAI.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)

            if isLegacyActiveProvider("Codex OAuth") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // MARK: - Default Group

        // If we found an active provider, narrow the group to the last selected model if possible
        if !firstGroupEntryIds.isEmpty {
            // Try to match legacy AgentModelSettings primary model IDs
            let legacySettings = Self.loadLegacyAgentModelSettings()
            let primaryIds = legacySettings.primaryModelIds

            // Filter to just entries matching the legacy primary model IDs
            let matchedEntries = firstGroupEntryIds.filter { entryId in
                primaryIds.contains(where: { entryId.hasSuffix(":\($0)") })
            }

            let groupMembers = matchedEntries.isEmpty ? firstGroupEntryIds : matchedEntries

            let defaultGroup = ModelGroup(
                name: "Default",
                memberEntryIds: groupMembers,
                strategy: groupMembers.count > 1 ? .fallback : .fallback
            )
            config.modelGroups.append(defaultGroup)
            config.defaultPrimaryGroupId = defaultGroup.id

            // Sub-model group from legacy settings
            let subIds = legacySettings.subModelIds.isEmpty ? legacySettings.primaryModelIds : legacySettings.subModelIds
            if subIds != primaryIds {
                let subEntries = firstGroupEntryIds.filter { entryId in
                    subIds.contains(where: { entryId.hasSuffix(":\($0)") })
                }
                if !subEntries.isEmpty {
                    let subGroup = ModelGroup(
                        name: "Sub Tasks",
                        memberEntryIds: subEntries,
                        strategy: .fallback
                    )
                    config.modelGroups.append(subGroup)
                    config.defaultSubGroupId = subGroup.id
                }
            }
        }

        store.applyConfig(config)

        logger.info("Migration created \(config.instances.count) instances, \(config.modelEntries.count) entries, \(config.modelGroups.count) groups")
    }

    // MARK: - Legacy Helpers

    private static func readLegacyKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Legacy AgentModelSettings shape (for migration only).
    private struct LegacyAgentModelSettings: Codable {
        var primaryModelIds: [String]
        var subModelIds: [String]
    }

    private static func loadLegacyAgentModelSettings() -> LegacyAgentModelSettings {
        let key = "com.claudio.app.agent-model-settings"
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(LegacyAgentModelSettings.self, from: data)
        else {
            return LegacyAgentModelSettings(primaryModelIds: [LLMModel.claudeSonnet46.id], subModelIds: [])
        }
        return settings
    }

    /// Check if a given raw auth mode string matches the legacy active provider keychain entry.
    private static func isLegacyActiveProvider(_ rawValue: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.claudio.app.active-provider",
            kSecAttrAccount as String: "auth-mode",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let raw = String(data: data, encoding: .utf8) else { return false }
        return raw == rawValue
    }
}
