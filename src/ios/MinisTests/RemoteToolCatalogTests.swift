// [Claudio 2026-09-08] RemoteToolCatalog 映射规则 + 本地隔离边界 pin。
//
// 为什么存在：注册表是远端工具卡文案的唯一事实源。两类回归必须即红：
// 1) 远端名映射错（Read 卡不显示文件名、Grep 摘要丢 pattern）
// 2) 本地名误入注册表（本地 agent 卡片被远端文案劫持——隔离铁律）
//
// 注意：CI unit-tests 步骤当前挂起（if: false），本文件暂不跑；
// 测试基建恢复时随存量一起执行。

import XCTest
@testable import Minis

final class RemoteToolCatalogTests: XCTestCase {

    // MARK: - 隔离边界（本地名绝不进注册表）

    func testLocalToolNamesAreNotRemote() {
        for name in ["file_read", "file_write", "file_edit", "shell_execute",
                     "browser_use", "read_image", "memory_write", "memory_get"] {
            XCTAssertFalse(RemoteToolCatalog.isRemoteTool(name), "\(name) 不应被判为远端工具")
        }
    }

    func testClaudeCodeNamesAreRemote() {
        for name in ["Read", "Write", "Edit", "MultiEdit", "Bash", "Glob", "Grep",
                     "WebSearch", "WebFetch", "Task", "TodoWrite", "AskUserQuestion"] {
            XCTAssertTrue(RemoteToolCatalog.isRemoteTool(name), "\(name) 应被判为远端工具")
        }
    }

    func testMcpPrefixedNamesAreRemote() {
        XCTAssertTrue(RemoteToolCatalog.isRemoteTool("mcp__change-title__change_title"))
        XCTAssertTrue(RemoteToolCatalog.isRemoteTool("mcp__github__get_issue"))
    }

    func testUnknownNameIsNotRemote() {
        XCTAssertFalse(RemoteToolCatalog.isRemoteTool("SomeFutureTool"))
        XCTAssertFalse(RemoteToolCatalog.isRemoteTool(""))
    }

    // MARK: - 块类型映射（官方渲染规则）

    func testReadMapsFilePath() {
        let kind = RemoteToolCatalog.blockKind(
            for: "Read", args: ["file_path": "/home/ubuntu/claudio/README.md"])
        XCTAssertEqual(kind, .fileReadTool(path: "/home/ubuntu/claudio/README.md"))
        // 卡片文案 = 文件名（AssistantBlock.toolDescription 官方规则）
        let block = AssistantBlock(kind: kind, content: "")
        XCTAssertEqual(block.toolDescription, "README.md")
    }

    func testReadWithoutFilePathFallsBackToGeneric() {
        let block = AssistantBlock(
            kind: RemoteToolCatalog.blockKind(for: "Read", args: [:]), content: "")
        XCTAssertEqual(block.toolDescription, "Read file")
    }

    func testBashMapsCommand() {
        let kind = RemoteToolCatalog.blockKind(
            for: "Bash", args: ["command": "git status"])
        XCTAssertEqual(kind, .shellTool(command: "git status"))
        let block = AssistantBlock(kind: kind, content: "")
        XCTAssertEqual(block.toolDescription, "git status")
    }

    func testGrepMapsQuotedPattern() {
        let kind = RemoteToolCatalog.blockKind(
            for: "Grep", args: ["pattern": "RemoteToolCatalog"])
        XCTAssertEqual(kind, .shellTool(command: "pattern: \"RemoteToolCatalog\""))
    }

    func testEditMapsFilePath() {
        let kind = RemoteToolCatalog.blockKind(
            for: "Edit", args: ["file_path": "/a/b/main.swift"])
        XCTAssertEqual(kind, .fileEditTool(path: "/a/b/main.swift"))
    }

    func testWebSearchMapsQuery() {
        let kind = RemoteToolCatalog.blockKind(
            for: "WebSearch", args: ["query": "swift concurrency"])
        XCTAssertEqual(kind, .browserTool(action: "swift concurrency"))
    }

    func testTodoWriteCountsTodos() {
        let todos: [[String: Any]] = [
            ["content": "a"], ["content": "b"], ["content": "c"],
        ]
        let kind = RemoteToolCatalog.blockKind(
            for: "TodoWrite", args: ["todos": todos])
        guard case .memoryTool(let action) = kind else {
            return XCTFail("expected memoryTool")
        }
        XCTAssertEqual(action, "todo list · 3 items")
    }

    func testAskUserQuestionReadsQuestionsArray() {
        let questions: [[String: Any]] = [["question": "用哪个方案？", "options": []]]
        let kind = RemoteToolCatalog.blockKind(
            for: "AskUserQuestion", args: ["questions": questions])
        guard case .memoryTool(let action) = kind else {
            return XCTFail("expected memoryTool")
        }
        XCTAssertEqual(action, "用哪个方案？")
    }

    func testMcpToolFallsBackToOtherSummary() {
        let kind = RemoteToolCatalog.blockKind(
            for: "mcp__change-title__change_title",
            args: ["title": "重构登录模块"])
        guard case .memoryTool(let action) = kind else {
            return XCTFail("expected memoryTool")
        }
        XCTAssertEqual(action, "title")
    }

    func testSummaryTruncation() {
        let long = String(repeating: "a", count: 120)
        let kind = RemoteToolCatalog.blockKind(
            for: "mcp__x__y", args: ["description": long])
        guard case .memoryTool(let action) = kind else {
            return XCTFail("expected memoryTool")
        }
        XCTAssertEqual(action.count, 51) // 50 chars + ellipsis
        XCTAssertTrue(action.hasSuffix("…"))
    }

    // MARK: - 流式预览文案

    func testStreamingPreviewRead() {
        let preview = RemoteToolCatalog.streamingPreview(
            for: "Read", args: ["file_path": "/a/b/main.swift"])
        XCTAssertEqual(preview, "Reading main.swift…")
    }

    func testStreamingPreviewBash() {
        let preview = RemoteToolCatalog.streamingPreview(
            for: "Bash", args: ["command": "git status"])
        XCTAssertEqual(preview, "Running git status…")
    }

    func testStreamingPreviewLocalNameNeverRouted() {
        // 本地名即使误调用注册表，也不该产出远端文案——门卫第一层兜底。
        XCTAssertFalse(RemoteToolCatalog.isRemoteTool("file_read"))
    }
}
