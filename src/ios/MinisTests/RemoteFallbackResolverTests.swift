// [Claudio 2026-09-07 P0] Pin 远端兜底决策 + 默认 tab 决策的隔离边界。
//
// 为什么存在：pp 铁律「本地和远端是分开的，不影响本地 agent 正常使用」。
// resolveCurrentEntry 的远端兜底与 RemoteNewSessionSheet 默认 tab 都含
// 「本地/远端」边界判断——未来 refactor 把"本地可用"判定改松，本地用户
// 就会被静默切到远端。这些测试把边界条件 pin 死，回归即红。
//
// 覆盖矩阵：
//   remoteFallbackDecision ——
//     1. 有可用本地 → keepLocalPath（铁律主闸）
//     2. 本地存在但禁用/无 credential/隐藏 → 不算可用 → 兜底
//     3. remoteAgent 类型的 entry 不算"本地可用"
//     4. 无可用本地 + 有可用远端 → fallBackToRemote
//     5. 远端禁用/无 credential → keepLocalPath
//     6. 远端 entry 全隐藏 → keepLocalPath
//     7. 多远端实例 → 第一个可用的
//     8. 空快照 → keepLocalPath
//   remoteDefaultTab ——
//     9. 记忆 claude/codex/nil
//     10. 四象限：双可用→onDevice（本地优先）；仅远端→claude；仅本地→onDevice；全无→onDevice

import XCTest
@testable import Minis

// [Fix 2026-09-11] CI 实锤：remoteFallbackDecision 是 @MainActor 类
// AIChatViewModel 的 static 方法（extension 继承 actor 隔离），同步测试
// 调用需要本测试类同样隔离到 MainActor（仓库既有 5 个测试文件同款先例）。
@MainActor
final class RemoteFallbackResolverTests: XCTestCase {

    // MARK: - 快照构建 helper

    private func instance(
        id: String,
        type: ProviderType = .anthropic,
        enabled: Bool = true,
        credentialed: Bool = true
    ) -> AIChatViewModel.RemoteFallbackSnapshot.InstanceSnapshot {
        .init(id: id, providerType: type, isEnabled: enabled, hasCredential: credentialed)
    }

    private func entry(
        id: String,
        instance: String,
        hidden: Bool = false
    ) -> AIChatViewModel.RemoteFallbackSnapshot.EntrySnapshot {
        .init(id: id, instanceId: instance, isHidden: hidden)
    }

    private func snap(
        instances: [AIChatViewModel.RemoteFallbackSnapshot.InstanceSnapshot],
        entries: [AIChatViewModel.RemoteFallbackSnapshot.EntrySnapshot]
    ) -> AIChatViewModel.RemoteFallbackSnapshot {
        .init(instances: instances, entries: entries)
    }

    // MARK: - 1. 铁律主闸：有可用本地绝不兜底

    func test_usableLocalExists_neverFallsBack() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [
                instance(id: "local1", type: .anthropic),
                instance(id: "remote1", type: .remoteAgent),
            ],
            entries: [
                entry(id: "e-local", instance: "local1"),
                entry(id: "e-remote", instance: "remote1"),
            ]
        ))
        XCTAssertEqual(d, .keepLocalPath)
    }

    // MARK: - 2. 本地"存在但不可用"不阻止兜底

    func test_disabledLocal_fallsBackToRemote() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [
                instance(id: "local1", type: .anthropic, enabled: false),
                instance(id: "remote1", type: .remoteAgent),
            ],
            entries: [
                entry(id: "e-local", instance: "local1"),
                entry(id: "e-remote", instance: "remote1"),
            ]
        ))
        XCTAssertEqual(d, .fallBackToRemote(instanceId: "remote1", entryId: "e-remote"))
    }

    func test_credentiallessLocal_fallsBackToRemote() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [
                instance(id: "local1", type: .anthropic, credentialed: false),
                instance(id: "remote1", type: .remoteAgent),
            ],
            entries: [
                entry(id: "e-local", instance: "local1"),
                entry(id: "e-remote", instance: "remote1"),
            ]
        ))
        XCTAssertEqual(d, .fallBackToRemote(instanceId: "remote1", entryId: "e-remote"))
    }

    func test_hiddenLocalEntry_doesNotBlockFallback() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [
                instance(id: "local1", type: .anthropic),
                instance(id: "remote1", type: .remoteAgent),
            ],
            entries: [
                entry(id: "e-local", instance: "local1", hidden: true),
                entry(id: "e-remote", instance: "remote1"),
            ]
        ))
        XCTAssertEqual(d, .fallBackToRemote(instanceId: "remote1", entryId: "e-remote"))
    }

    // MARK: - 3. remoteAgent 的 entry 不算"本地可用"

    func test_remoteAgentEntry_aloneDoesNotBlockFallback() {
        // 只有一个远端实例（唯一 entry 归属 remoteAgent）——hasUsableLocalEntry
        // 必须为 false，否则永远兜不了底。
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [instance(id: "remote1", type: .remoteAgent)],
            entries: [entry(id: "e-remote", instance: "remote1")]
        ))
        XCTAssertEqual(d, .fallBackToRemote(instanceId: "remote1", entryId: "e-remote"))
    }

    // MARK: - 4/5. 远端不可用 → keepLocalPath（原链路继续，最终 nil 报错不变）

    func test_disabledRemote_keepsLocalPath() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [instance(id: "remote1", type: .remoteAgent, enabled: false)],
            entries: [entry(id: "e-remote", instance: "remote1")]
        ))
        XCTAssertEqual(d, .keepLocalPath)
    }

    func test_credentiallessRemote_keepsLocalPath() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [instance(id: "remote1", type: .remoteAgent, credentialed: false)],
            entries: [entry(id: "e-remote", instance: "remote1")]
        ))
        XCTAssertEqual(d, .keepLocalPath)
    }

    // MARK: - 6. 远端 entry 全隐藏 → keepLocalPath

    func test_allRemoteEntriesHidden_keepsLocalPath() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [instance(id: "remote1", type: .remoteAgent)],
            entries: [entry(id: "e-remote", instance: "remote1", hidden: true)]
        ))
        XCTAssertEqual(d, .keepLocalPath)
    }

    // MARK: - 7. 多远端实例 → 第一个可用者胜

    func test_multipleRemotes_picksFirstUsable() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(
            instances: [
                instance(id: "remoteA", type: .remoteAgent, enabled: false),
                instance(id: "remoteB", type: .remoteAgent),
            ],
            entries: [
                entry(id: "e-a", instance: "remoteA"),
                entry(id: "e-b", instance: "remoteB"),
            ]
        ))
        XCTAssertEqual(d, .fallBackToRemote(instanceId: "remoteB", entryId: "e-b"))
    }

    // MARK: - 8. 空快照

    func test_emptySnapshot_keepsLocalPath() {
        let d = AIChatViewModel.remoteFallbackDecision(from: snap(instances: [], entries: []))
        XCTAssertEqual(d, .keepLocalPath)
    }

    // MARK: - 9/10. 默认 tab 决策

    func test_defaultTab_savedProviderWins() {
        XCTAssertEqual(
            RemoteNewSessionTabProbe.remoteDefaultTab(
                savedProvider: "claude", hasUsableLocal: true, hasUsableRemote: true),
            .claude)
        XCTAssertEqual(
            RemoteNewSessionTabProbe.remoteDefaultTab(
                savedProvider: "codex", hasUsableLocal: true, hasUsableRemote: true),
            .codex)
    }

    func test_defaultTab_bothUsable_onDeviceWins() {
        // 第 0 原则：双可用 → 本地优先
        XCTAssertEqual(
            RemoteNewSessionTabProbe.remoteDefaultTab(
                savedProvider: nil, hasUsableLocal: true, hasUsableRemote: true),
            .onDevice)
    }

    func test_defaultTab_remoteOnly_claude() {
        XCTAssertEqual(
            RemoteNewSessionTabProbe.remoteDefaultTab(
                savedProvider: nil, hasUsableLocal: false, hasUsableRemote: true),
            .claude)
    }

    func test_defaultTab_localOnly_onDevice() {
        XCTAssertEqual(
            RemoteNewSessionTabProbe.remoteDefaultTab(
                savedProvider: nil, hasUsableLocal: true, hasUsableRemote: false),
            .onDevice)
    }

    func test_defaultTab_noneUsable_onDevice() {
        XCTAssertEqual(
            RemoteNewSessionTabProbe.remoteDefaultTab(
                savedProvider: nil, hasUsableLocal: false, hasUsableRemote: false),
            .onDevice)
    }
}
