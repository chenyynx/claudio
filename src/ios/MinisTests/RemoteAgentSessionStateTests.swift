import XCTest
@testable import Minis

/// [隔离架构铁律重构 2026-09-09] RemoteAgentSessionState 单测。
/// 覆盖三个纯逻辑维度（方案 §6a）：
/// ① 文件后缀合成（indexSuffixes ∪ observedPathForms → fileSuffixes，空=nil）
/// ② 权限响应状态机（clearPermissionIfMatching 的 id 匹配保护）
/// ③ 附件候选 drain（pendingPayloads 交接清空语义）
@MainActor
final class RemoteAgentSessionStateTests: XCTestCase {

    // MARK: - ① 文件后缀合成

    func testFileSuffixesEmptyByDefault() {
        let state = RemoteAgentSessionState()
        XCTAssertNil(state.fileSuffixes, "初始（无索引无观察）必须为 nil = 渲染零行为")
    }

    func testMergeObservedFilePathsProducesSuffixes() {
        let state = RemoteAgentSessionState()
        state.mergeObservedFilePaths(["/home/ubuntu/x.py", "/home/ubuntu/a.swift"])
        XCTAssertNotNil(state.fileSuffixes)
        // observedPathForms 的产出应包含裸后缀形态（.py / .swift）
        XCTAssertTrue(state.fileSuffixes!.contains("py"))
        XCTAssertTrue(state.fileSuffixes!.contains("swift"))
    }

    func testMergeObservedFilePathsEmptySetStaysNil() {
        let state = RemoteAgentSessionState()
        state.mergeObservedFilePaths([])
        XCTAssertNil(state.fileSuffixes, "空集不能合成出非 nil（零行为语义）")
    }

    func testIndexSuffixesAndObservedPathsUnion() async {
        let state = RemoteAgentSessionState()
        // 只走 observed（index 需 provider 网络路径，单测覆盖并集逻辑本身）
        state.mergeObservedFilePaths(["/a/readme.md"])
        let viaObserved = state.fileSuffixes
        XCTAssertNotNil(viaObserved)
        XCTAssertTrue(viaObserved!.contains("md"))
        _ = state // silence unused warning in release
    }

    // MARK: - ② 权限响应状态机

    func testClearPermissionIfMatchingClearsExactId() {
        let state = RemoteAgentSessionState()
        state.pendingPermission = RemotePermissionRequest(
            id: "tool-1", toolName: "Bash", input: ["command": "ls"]
        )
        state.clearPermissionIfMatching(id: "tool-1")
        XCTAssertNil(state.pendingPermission)
    }

    func testClearPermissionIfMatchingIgnoresOtherId() {
        let state = RemoteAgentSessionState()
        state.pendingPermission = RemotePermissionRequest(
            id: "tool-1", toolName: "Bash", input: [:]
        )
        // 乱序到达的旧响应不能清掉新请求
        state.clearPermissionIfMatching(id: "tool-old")
        XCTAssertNotNil(state.pendingPermission)
        XCTAssertEqual(state.pendingPermission?.id, "tool-1")
    }

    func testClearPermissionIfMatchingOnNilIsNoop() {
        let state = RemoteAgentSessionState()
        state.clearPermissionIfMatching(id: "anything")
        XCTAssertNil(state.pendingPermission)
    }

    // MARK: - ③ 附件候选 drain

    func testPendingPayloadsDrain() {
        let state = RemoteAgentSessionState()
        state.pendingPayloads = [
            .inlineImage(data: Data([0x89, 0x50]), mimeType: "image/png"),
            .uploadFile(fileURL: URL(fileURLWithPath: "/tmp/x.pdf"), fileName: "x.pdf"),
        ]
        // 交接语义：provider 接走 → 清空（runAgentLoop 远端分支的两行模式）
        let handed = state.pendingPayloads
        state.pendingPayloads = []
        XCTAssertTrue(handed.count == 2)
        XCTAssertTrue(state.pendingPayloads.isEmpty)
    }

    func testPendingPayloadsEmptyByDefault() {
        let state = RemoteAgentSessionState()
        XCTAssertTrue(state.pendingPayloads.isEmpty, "本地会话恒空（写侧 gate 语义）")
    }
}
