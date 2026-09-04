import Foundation
import Combine

/// 远端(Bridge 侧)可用模型目录的客户端缓存。
///
/// 桥在每次 `session_list` 广播里都带 `claudeModels` / `claudeModelEfforts`
/// / `codexModels` 等字段（参考 ccpocket websocket.ts:7780+）。本类负责
/// 解析 → 缓存 → 暴露给 UI 层。`@MainActor` 单例，与 `BridgeSessionRegistry`
/// 风格保持一致。
///
/// 数据流：CCPocketClient 收到 session_list → RemoteModelCatalog.apply
/// 写 → 触发 @Published → UI 重新渲染 Model 下拉 + Effort chip。
///
/// 持久化：写一份到 UserDefaults（`ccpocket.modelCatalog.v1.<instanceID>`
/// 命名空间），连接断开后 UI 仍能展示上次结果。
///
/// 隔离：多 provider instance 场景下按 instanceID 分别缓存（同一台 iOS
/// 上连了多个 Bridge 实例时互不干扰）。
@MainActor
final class RemoteModelCatalog: ObservableObject {
    static let shared = RemoteModelCatalog()

    /// instanceID → 该实例的模型目录快照
    @Published private(set) var catalogByInstance: [String: ModelCatalog] = [:]

    private static let storageKey = "ccpocket.modelCatalog.v1"

    private init() {
        // 启动时从 UserDefaults 加载最近一次快照,保证 UI 在没连桥时
        // 也能展示缓存的模型列表(降级语义同 BridgeSessionRegistry)。
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let restored = try? JSONDecoder().decode([String: ModelCatalog].self, from: data) {
            self.catalogByInstance = restored
        }
    }

    // MARK: - Public API

    /// 当前活跃实例(取最近一次 apply 过 / 当前 UI 选中那个)的模型目录
    /// 便捷取数。`instanceID` 传 nil 时取最新 apply 过的那个实例。
    func claudeModels(for instanceID: String? = nil) -> [String] {
        let cat = catalog(for: instanceID)
        return cat?.claudeModels ?? []
    }

    func claudeModelEfforts(for model: String?, instanceID: String? = nil) -> [String] {
        guard let model else { return [] }
        let cat = catalog(for: instanceID)
        return cat?.claudeModelEfforts[model] ?? []
    }

    func codexModels(for instanceID: String? = nil) -> [String] {
        let cat = catalog(for: instanceID)
        return cat?.codexModels ?? []
    }

    func codexProfiles(for instanceID: String? = nil) -> [String] {
        let cat = catalog(for: instanceID)
        return cat?.codexProfiles ?? []
    }

    func defaultCodexProfile(for instanceID: String? = nil) -> String? {
        let cat = catalog(for: instanceID)
        return cat?.defaultCodexProfile
    }

    /// 判断 model 是否支持 effort 等级(用于 UI 显示 "不支持" 提示)。
    func supportsEffort(model: String?, instanceID: String? = nil) -> Bool {
        !claudeModelEfforts(for: model, instanceID: instanceID).isEmpty
    }

    // MARK: - Write path (called from CCPocketClient session_list branch)

    /// 收到 session_list 广播时调用,把桥送来的 7 个模型字段全量写进
    /// 对应 instance 的目录。`message`-level apply 是与桥协议层对齐
    /// 的入口(避免 CCPocketClient.swift 暴露 7 个单独 setter)。
    func apply(instanceID: String,
               claudeModels: [String]?,
               claudeModelEfforts: [String: [String]]?,
               codexModels: [String]?,
               codexModelReasoningEfforts: [String: [String]]?,
               codexModelServiceTiers: [String: [String]]?,
               codexProfiles: [String]?,
               defaultCodexProfile: String?) {
        // 桥有时会送空(nil 或 []) — 不覆盖已有缓存,降级为保留上次结果。
        // 这样桥临时广播空(重启中)不会让 UI 模型列表突然消失。
        let new = ModelCatalog(
            claudeModels: claudeModels ?? catalogByInstance[instanceID]?.claudeModels ?? [],
            claudeModelEfforts: claudeModelEfforts ?? catalogByInstance[instanceID]?.claudeModelEfforts ?? [:],
            codexModels: codexModels ?? catalogByInstance[instanceID]?.codexModels ?? [],
            codexModelReasoningEfforts: codexModelReasoningEfforts ?? catalogByInstance[instanceID]?.codexModelReasoningEfforts ?? [:],
            codexModelServiceTiers: codexModelServiceTiers ?? catalogByInstance[instanceID]?.codexModelServiceTiers ?? [:],
            codexProfiles: codexProfiles ?? catalogByInstance[instanceID]?.codexProfiles ?? [],
            defaultCodexProfile: defaultCodexProfile ?? catalogByInstance[instanceID]?.defaultCodexProfile,
            updatedAt: Date()
        )
        catalogByInstance[instanceID] = new
        persist()
    }

    // MARK: - Internals

    private func catalog(for instanceID: String?) -> ModelCatalog? {
        if let id = instanceID, let cat = catalogByInstance[id] {
            return cat
        }
        // nil → 取最近一次 apply 过的实例
        return catalogByInstance.values.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(catalogByInstance) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// 一个 Bridge 实例的模型目录快照。所有字段 default 为空,JSON 解码
/// 缺字段时优雅降级(桥的 broadcast 是可扩展的,字段会慢慢加)。
struct ModelCatalog: Codable, Equatable, Sendable {
    var claudeModels: [String]
    var claudeModelEfforts: [String: [String]]
    var codexModels: [String]
    var codexModelReasoningEfforts: [String: [String]]
    var codexModelServiceTiers: [String: [String]]
    var codexProfiles: [String]
    var defaultCodexProfile: String?
    var updatedAt: Date

    init(claudeModels: [String] = [],
         claudeModelEfforts: [String: [String]] = [:],
         codexModels: [String] = [],
         codexModelReasoningEfforts: [String: [String]] = [:],
         codexModelServiceTiers: [String: [String]] = [:],
         codexProfiles: [String] = [],
         defaultCodexProfile: String? = nil,
         updatedAt: Date = Date()) {
        self.claudeModels = claudeModels
        self.claudeModelEfforts = claudeModelEfforts
        self.codexModels = codexModels
        self.codexModelReasoningEfforts = codexModelReasoningEfforts
        self.codexModelServiceTiers = codexModelServiceTiers
        self.codexProfiles = codexProfiles
        self.defaultCodexProfile = defaultCodexProfile
        self.updatedAt = updatedAt
    }
}
