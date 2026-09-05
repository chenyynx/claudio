// [Fix 2026-09-05] Pin the `<user-attached-files>` XML contract that
// RemoteAgentProvider hands to the bridge agent. The format MUST match what
// the local agent produces (AIChatViewModel.swift:2662-2670) so that
// ChatStore.toChatMessage (4832-4900) parses the `<file>` element into
// AttachmentMeta and strips the XML from the user-visible bubble —
// otherwise the bug 2026-09-05 "remote file attach: agent can't find file
// + backfill leaks raw XML into chat" recurs.
//
// What this test pins:
//  1. Path = "<projectPath>/<fileName>" — agent uses this to `Read` the file
//  2. size attribute present and matches sizeBytes
//  3. modified attribute is valid ISO8601 with internet date time
//  4. ChatStore's existing `<file>` regex (ChatStore.swift:4845) extracts
//     the path/size/modified out of the produced XML (round-trip)
//  5. The XML is bracketed by the open/close tags the toChatMessage parser
//     looks for (ChatStore.swift:4835-4839), so backfill display stripping
//     works end-to-end.
//  6. Default `now` parameter uses real Date() (not pinned) — sanity smoke.

import XCTest
@testable import Minis

final class RemoteFileUploadTextPromptTests: XCTestCase {

    private let pinnedNow: Date = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: "2026-09-05T12:34:56Z")!
    }()

    // MARK: - 1. 路径 / 大小 / 时间 三件套

    func test_buildXML_embedsPathSizeAndISO8601Modified() {
        let xml = RemoteAgentProvider.buildUserAttachedFilesXML(
            projectPath: "/home/ubuntu",
            fileName: "probe-resume.pdf",
            sizeBytes: 501_237,
            now: pinnedNow
        )
        XCTAssertTrue(xml.contains("path=\"/home/ubuntu/probe-resume.pdf\""),
                      "agent 必须能从 path 读出文件位置，路径必须含 projectPath+fileName")
        XCTAssertTrue(xml.contains("size=\"501237\""),
                      "size 属性必须用十进制无单位字符串，agent 不解析千分位")
        XCTAssertTrue(xml.contains("modified=\"2026-09-05T12:34:56Z\""),
                      "modified 必须是 ISO8601 withInternetDateTime，ChatStore 解析用")
    }

    // MARK: - 2. XML 结构（被 ChatStore.toChatMessage 4835-4839 剥的开闭标签）

    func test_buildXML_usesExactOpenCloseTags_ChatStoreExpects() {
        let xml = RemoteAgentProvider.buildUserAttachedFilesXML(
            projectPath: "/tmp",
            fileName: "x.txt",
            sizeBytes: 1,
            now: pinnedNow
        )
        XCTAssertTrue(xml.contains("<user-attached-files>"),
                      "必须用 ChatStore.swift:4835 找的开标签，差一字符就剥不掉")
        XCTAssertTrue(xml.contains("</user-attached-files>"),
                      "必须用 ChatStore.swift:4836 找的闭标签，缺一个就回退到剥到末尾")
        XCTAssertTrue(xml.contains("<file ") && xml.contains("/>"),
                      "file 元素必须自闭合 <file ... /> 格式（ChatStore.swift:4846 正则要求）")
    }

    // MARK: - 3. ChatStore 正则能 round-trip 剥出来（端到端：生产 → 消费）

    /// The same regex ChatStore.swift:4845 uses to extract the <file> element
    /// from `<user-attached-files>` XML. If our XML drifts away from what this
    /// regex expects, attachment tiles stop rendering AND the XML leaks to the
    /// user bubble. We don't import the regex directly (it's fileprivate), so
    /// we re-state it here verbatim — if someone changes the regex they have
    /// to update BOTH this test AND ChatStore, which is the regression pin.
    func test_buildXML_isParseableByChatStoreFileRegex() throws {
        let xml = RemoteAgentProvider.buildUserAttachedFilesXML(
            projectPath: "/home/ubuntu",
            fileName: "probe-resume.pdf",
            sizeBytes: 501_237,
            now: pinnedNow
        )

        let pattern = #"<file\s+path="([^"]*)"(?:\s+url="([^"]*)")?(?:\s+size="([^"]*)")?(?:\s+modified="([^"]*)")?\s*/>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(xml.startIndex..., in: xml)
        let matches = regex.matches(in: xml, range: range)
        XCTAssertEqual(matches.count, 1, "ChatStore 解析失败 → 附件瓦片不显示 + XML 漏到 bubble")

        let nsXml = xml as NSString
        let m = matches[0]
        let path = nsXml.substring(with: m.range(at: 1))
        let url = nsXml.substring(with: m.range(at: 2))
        let size = nsXml.substring(with: m.range(at: 3))
        let modified = nsXml.substring(with: m.range(at: 4))

        XCTAssertEqual(path, "/home/ubuntu/probe-resume.pdf")
        XCTAssertEqual(url, "", "url 可选，远端 agent 不传 minisURL（iOS 内部协议）")
        XCTAssertEqual(size, "501237")
        XCTAssertEqual(modified, "2026-09-05T12:34:56Z")
    }

    // MARK: - 4. 完整一段 inputText 长得对（user 输入 + XML，agent 收到的是这两块的拼接）

    func test_inputTextShape_userTextPlusXML() {
        let userText = "What is on the first page of this PDF?"
        let xml = RemoteAgentProvider.buildUserAttachedFilesXML(
            projectPath: "/home/ubuntu",
            fileName: "probe-resume.pdf",
            sizeBytes: 501_237,
            now: pinnedNow
        )
        // Production in RemoteAgentProvider.swift:222:
        //   inputText += "\n\n\(xml)"
        let inputText = userText + "\n\n" + xml

        XCTAssertTrue(inputText.hasPrefix(userText),
                      "agent 必须先看到用户输入，再看到 XML（否则语义顺序反了）")
        XCTAssertTrue(inputText.contains("\n\n<user-attached-files>"),
                      "user text 和 XML 之间必须有 \\n\\n 分隔（生产代码约定）")
        XCTAssertTrue(inputText.hasSuffix("</user-attached-files>"),
                      "inputText 必须以 XML 收尾（最后的附件）")
    }

    // MARK: - 5. 默认 now 走 Date()（sanity：不让 default 参数破坏 Date 来源）

    func test_buildXML_defaultNow_isCloseToNow() {
        let before = Date()
        let xml = RemoteAgentProvider.buildUserAttachedFilesXML(
            projectPath: "/tmp",
            fileName: "a.bin",
            sizeBytes: 0
        )
        let after = Date()

        // 抓 modified 字段解析回来，断言落在 [before, after] 区间（容许 5s 漂移）
        let pattern = #"modified="([^"]*)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(xml.startIndex..., in: xml)
        let match = regex.firstMatch(in: xml, range: range)!
        let modifiedStr = (xml as NSString).substring(with: match.range(at: 1))
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let modifiedDate = f.date(from: modifiedStr)!

        XCTAssertGreaterThanOrEqual(modifiedDate, before.addingTimeInterval(-5))
        XCTAssertLessThanOrEqual(modifiedDate, after.addingTimeInterval(5))
    }

    // MARK: - 6. 边界：空 size / 路径含空格 / 中文文件名（未来回归 pin）

    func test_buildXML_chineseFilenameAndSpacesInPath() {
        let xml = RemoteAgentProvider.buildUserAttachedFilesXML(
            projectPath: "/Users/陈鹏/Documents",
            fileName: "简历 v2.pdf",
            sizeBytes: 1234,
            now: pinnedNow
        )
        // 注意：ChatStore 当前的正则不转义 path，文件名含 < > & " 会破 XML
        // （同本地 agent 行为，xml 转义是后续 follow-up，不在本次 fix 范围）。
        // 空格 / 中文 / 数字是安全字符，必须能原样保留。
        XCTAssertTrue(xml.contains("path=\"/Users/陈鹏/Documents/简历 v2.pdf\""),
                      "中文 / 空格文件名必须原样保留在 path 属性里")
    }
}
