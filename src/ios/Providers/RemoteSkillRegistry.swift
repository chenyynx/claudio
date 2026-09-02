import Foundation
import SwiftUI

// MARK: - 远端技能（bridge 服务器上的 Claude Code skills）
//
// 与本地 SkillStore（skills.db）完全隔离：这些技能活在服务器
// ~/.claude/skills + 项目 .claude/skills，由桥在 SDK 会话进程启动时广播
// `system/supported_commands` 推下来（skills 名单 + skillMetadata：
// name/desc/scope）。只做展示/发现——Claude 协议里技能经 `/skill-name`
// 文本命令触发（官方桥只把结构化 skills 字段喂给 Codex 进程），故不做
// 开关注入。按 bridge 实例分桶、UserDefaults 持久化，冷启动未重连前也能看到。

struct RemoteSkill: Identifiable, Equatable {
    let name: String
    let description: String
    let scope: String        // "project" 项目级 | "user" 用户级（官方 metadata）
    var id: String { name }

    var scopeLabel: String {
        switch scope {
        case "user": return "User"
        case "project": return "Project"
        default: return "Server"
        }
    }
}

@MainActor
final class RemoteSkillRegistry: ObservableObject {
    static let shared = RemoteSkillRegistry()

    @Published private(set) var skillsByInstance: [String: [RemoteSkill]] = [:]

    private let defaults = UserDefaults.standard
    private let keyPrefix = "ccpocket.remoteSkills.v1."

    private init() { load() }

    func skills(for instanceID: String) -> [RemoteSkill] {
        skillsByInstance[instanceID] ?? []
    }

    func update(instanceID: String, skills: [RemoteSkill]) {
        skillsByInstance[instanceID] = skills
        if let data = try? JSONEncoder().encode(skills) {
            defaults.set(data, forKey: keyPrefix + instanceID)
        }
    }

    /// Parse the bridge `system/supported_commands` payload into remote skills.
    /// Prefer rich `skillMetadata` (name/description/scope); fall back to the
    /// bare `skills` name list (descriptions empty, scope "project").
    nonisolated static func parse(message: CCPocketProtocol.ServerMessage) -> [RemoteSkill] {
        if let md = message.skillMetadata, !md.isEmpty {
            let fromMeta: [RemoteSkill] = md.compactMap { m in
                func s(_ key: String) -> String? {
                    if case .string(let v)? = m[key] { return v }
                    return nil
                }
                guard let name = s("name"), !name.isEmpty else { return nil }
                return RemoteSkill(
                    name: name,
                    description: s("description") ?? s("shortDescription") ?? "",
                    scope: s("scope") ?? "project"
                )
            }
            if !fromMeta.isEmpty { return fromMeta }
        }
        return (message.skills ?? []).map {
            RemoteSkill(name: $0, description: "", scope: "project")
        }
    }

    private func load() {
        for (key, _) in defaults.dictionaryRepresentation() where key.hasPrefix(keyPrefix) {
            let instanceID = String(key.dropFirst(keyPrefix.count))
            guard let data = defaults.data(forKey: key),
                  let skills = try? JSONDecoder().decode([RemoteSkill].self, from: data)
            else { continue }
            skillsByInstance[instanceID] = skills
        }
    }
}
