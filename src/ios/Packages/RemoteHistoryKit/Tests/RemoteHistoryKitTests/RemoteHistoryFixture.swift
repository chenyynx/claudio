// RemoteHistoryFixture — 远端历史校准测试的**共享构造夹具**。
//
// 为什么单列一个文件：五个新模块的用例都要造 `RawMessage`（13 个字段），
// 每个测试文件各抄一份 `row()` = 五份漂移源。夹具化后"造一行"只有一处定义。
//
// 仅测试目标使用（不进 app target）。

import Foundation
@testable import RemoteHistoryKit

enum RemoteHistoryFixture {

    static let sessionId = "test-session"

    static func row(
        id: String,
        role: MessageRole = .user,
        parts: [ContentPart] = [.text("hi")],
        clientMessageId: String? = nil,
        remoteTurnKey: String? = nil,
        sortOrder: Int = 0,
        errorInfo: String? = nil
    ) -> RawMessage {
        RawMessage(
            id: id, sessionId: sessionId, role: role,
            parts: parts, createdAt: Date(), tokenUsage: nil,
            reasoningContent: nil, streamInterruptCount: 0,
            sortOrder: sortOrder, errorInfo: errorInfo,
            clientMessageId: clientMessageId,
            remoteTurnKey: remoteTurnKey
        )
    }

    // MARK: - parts

    static func text(_ s: String) -> ContentPart { .text(s) }

    static func toolUse(id: String, name: String = "Read") -> ContentPart {
        .toolUse(ToolUse(toolUseId: id, name: name, input: "{}", description: nil, thoughtSignature: nil))
    }

    static func toolResult(id: String, output: String = "ok") -> ContentPart {
        .toolResult(ToolResult(
            toolUseId: id, output: output, success: true, mediaRef: nil,
            snapshot: nil, pageURL: nil, status: "success", outputFile: nil
        ))
    }

    // MARK: - 真机复现场景（pp 2026-09-13 00:06，日志 E3）

    /// live 聚合行：一个 assistant 回合的 **8 个 parts 挤在一行**。
    /// 与 `serverRowsForSameTurn()` 的 8 条服务端行内容逐 part 相同。
    static func liveAggregateRow(
        id: String = "B274A31B",
        turnKey: String? = "cmid-1",
        sortOrder: Int = 2,
        errorInfo: String? = nil
    ) -> RawMessage {
        row(
            id: id, role: .assistant,
            parts: [
                text("t25"), text("t77"),
                toolUse(id: "tu-1"), toolUse(id: "tu-2"), toolUse(id: "tu-3"),
                toolResult(id: "tu-1", output: "9865c"),
                toolResult(id: "tu-2", output: "11566c"),
                toolResult(id: "tu-3", output: "2403c"),
            ],
            remoteTurnKey: turnKey,
            sortOrder: sortOrder,
            errorInfo: errorInfo
        )
    }

    /// 同一回合的服务端扁平行：8 行各 1 part（bridge stable 形态 `bm-`）。
    static func serverRowsForSameTurn(userCmid: String = "cmid-1") -> [RawMessage] {
        [
            row(id: "bm-u1", role: .user, parts: [text("看图")], clientMessageId: userCmid),
            row(id: "bm-a1", role: .assistant, parts: [text("t25")]),
            row(id: "bm-a2", role: .assistant, parts: [toolUse(id: "tu-1")]),
            row(id: "bm-a3", role: .assistant, parts: [toolResult(id: "tu-1", output: "9865c")]),
            row(id: "bm-a4", role: .assistant, parts: [toolUse(id: "tu-2")]),
            row(id: "bm-a5", role: .assistant, parts: [toolResult(id: "tu-2", output: "11566c")]),
            row(id: "bm-a6", role: .assistant, parts: [toolUse(id: "tu-3")]),
            row(id: "bm-a7", role: .assistant, parts: [toolResult(id: "tu-3", output: "2403c")]),
            row(id: "bm-a8", role: .assistant, parts: [text("t77")]),
        ]
    }
}
