// [Claudio 2026-09-06] Pin 远端文件 peek 核心契约（ccpocket file_peek 对齐）。
//
// 覆盖：
//   - buildSuffixSet：路径 → 全部后缀（lib/models/msg.dart → 3 个）
//   - matches：exact / suffix / 行号剥除（:42 / :42:10）
//   - stripLineCol：ccpocket file_path_syntax.dart _stripLineCol 对齐
//   - RemoteFileContent.parseTextResponse：kind=text / image / error 路由
//   - RemoteFileContent.parseMediaResponse：mediaUrl 相对路径 → 完整 http URL
//   - isMediaFile：audio/video 扩展名判定（ccpocket mediaFileTypesByExtension）
//
// 注：网络层（list_files / read_file / read_media_file RPC）不在本测试
//     范围 — 需要 mock CCPocketClient，留给 future PR。上面全是纯函数，
//     先 pin 死契约。

import XCTest
@testable import Minis

final class RemoteFilePeekTests: XCTestCase {

    // MARK: - buildSuffixSet

    func test_buildSuffixSet_generatesAllSuffixes() {
        let set = RemoteFileIndexEntry.buildSuffixSet(from: ["lib/models/messages.dart"])
        XCTAssertEqual(set, [
            "lib/models/messages.dart",
            "models/messages.dart",
            "messages.dart",
        ])
    }

    func test_buildSuffixSet_skipsTrailingSlash() {
        let set = RemoteFileIndexEntry.buildSuffixSet(from: ["src/ui/"])
        XCTAssertEqual(set, [])
    }

    func test_buildSuffixSet_dedupesSharedSuffixes() {
        let set = RemoteFileIndexEntry.buildSuffixSet(from: [
            "a/messages.dart",
            "b/messages.dart",
        ])
        XCTAssertTrue(set.contains("messages.dart"))
        XCTAssertEqual(set.count(where: { $0 == "messages.dart" }), 1)
    }

    // MARK: - stripLineCol

    func test_stripLineCol_removesLineColSuffix() {
        XCTAssertEqual(RemoteProjectFileIndex.stripLineCol("foo.swift:42"), "foo.swift")
        XCTAssertEqual(RemoteProjectFileIndex.stripLineCol("foo.swift:42:10"), "foo.swift")
    }

    func test_stripLineCol_keepsPlainPath() {
        XCTAssertEqual(RemoteProjectFileIndex.stripLineCol("foo.swift"), "foo.swift")
        XCTAssertEqual(RemoteProjectFileIndex.stripLineCol("src/foo.swift"), "src/foo.swift")
    }


    // MARK: - mergingAbsoluteForms [Claudio 2026-09-07]

    func test_mergingAbsoluteForms_addsRootPrefixedForms() {
        let rel: Set<String> = ["claudio/README.md", "README.md"]
        let merged = RemoteFileIndexEntry.mergingAbsoluteForms(rel, projectRoot: "/home/ubuntu")
        XCTAssertEqual(merged, [
            "claudio/README.md", "README.md",
            "/home/ubuntu/claudio/README.md", "/home/ubuntu/README.md",
        ])
    }

    func test_mergingAbsoluteForms_trailingSlashRoot_noDoubleSlash() {
        let merged = RemoteFileIndexEntry.mergingAbsoluteForms(["a.md"], projectRoot: "/home/ubuntu/")
        XCTAssertTrue(merged.contains("/home/ubuntu/a.md"))
        XCTAssertFalse(merged.contains("//home/ubuntu/a.md"))
    }

    func test_mergingAbsoluteForms_emptyRoot_returnsUnchanged() {
        let rel: Set<String> = ["a.md"]
        XCTAssertEqual(RemoteFileIndexEntry.mergingAbsoluteForms(rel, projectRoot: ""), rel)
    }

    func test_matches_absoluteFormHitsAfterMerge() {
        // 端到端 pin：合并后绝对路径必须命中（回归保护 — 修复前永远 false）
        let set = RemoteFileIndexEntry.mergingAbsoluteForms(
            RemoteFileIndexEntry.buildSuffixSet(from: ["claudio/README.md"]),
            projectRoot: "/home/ubuntu"
        )
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "/home/ubuntu/claudio/README.md", suffixSet: set))
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "/home/ubuntu/README.md", suffixSet: set))
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "claudio/README.md", suffixSet: set))
        // 行号后缀 + 绝对形态组合
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "/home/ubuntu/claudio/README.md:42", suffixSet: set))
    }

    // MARK: - matches

    func test_matches_exactSuffix() {
        let set: Set<String> = ["src/foo.swift"]
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "src/foo.swift", suffixSet: set))
    }

    func test_matches_partialSuffix() {
        let set = RemoteFileIndexEntry.buildSuffixSet(from: ["lib/models/msg.dart"])
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "models/msg.dart", suffixSet: set))
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "msg.dart", suffixSet: set))
    }

    func test_matches_stripsLineColBeforeMatch() {
        let set = RemoteFileIndexEntry.buildSuffixSet(from: ["src/foo.swift"])
        XCTAssertTrue(RemoteProjectFileIndex.matches(path: "foo.swift:42", suffixSet: set))
    }

    func test_matches_rejectsUnknownPath() {
        let set = RemoteFileIndexEntry.buildSuffixSet(from: ["src/foo.swift"])
        XCTAssertFalse(RemoteProjectFileIndex.matches(path: "github.com/foo", suffixSet: set))
        XCTAssertFalse(RemoteProjectFileIndex.matches(path: "1.2.3", suffixSet: set))
    }

    // MARK: - parseTextResponse

    private func textResponse(
        kind: String = "text",
        content: String = "",
        language: String? = nil,
        totalLines: Int? = nil,
        truncated: Bool? = nil,
        base64: String? = nil,
        mimeType: String? = nil,
        sizeBytes: Int64? = nil,
        mediaUrl: String? = nil,
        error: String? = nil
    ) -> CCPocketProtocol.FileContentResponse {
        CCPocketProtocol.FileContentResponse(
            kind: kind,
            content: content,
            language: language,
            totalLines: totalLines,
            truncated: truncated,
            base64: base64,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            mediaUrl: mediaUrl,
            filePath: nil,
            error: error
        )
    }

    func test_parseTextResponse_textKind() {
        let content = RemoteFileContentFetcher.parseTextResponse(textResponse(
            content: "let x = 1",
            language: "swift",
            totalLines: 3,
            truncated: false
        ))
        guard case .text(let text, let lang, let lines, let truncated) = content else {
            return XCTFail("expected .text, got \(content)")
        }
        XCTAssertEqual(text, "let x = 1")
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(lines, 3)
        XCTAssertEqual(truncated, false)
    }

    func test_parseTextResponse_imageKind() {
        let content = RemoteFileContentFetcher.parseTextResponse(textResponse(
            kind: "image",
            base64: "aGVsbG8=",
            mimeType: "image/png",
            sizeBytes: 1234
        ))
        guard case .image(let b64, let mime, let size) = content else {
            return XCTFail("expected .image, got \(content)")
        }
        XCTAssertEqual(b64, "aGVsbG8=")
        XCTAssertEqual(mime, "image/png")
        XCTAssertEqual(size, 1234)
    }

    func test_parseTextResponse_errorTakesPriority() {
        let content = RemoteFileContentFetcher.parseTextResponse(textResponse(
            kind: "image",
            error: "Image too large to preview. Maximum size is 5 MB."
        ))
        guard case .failed(let error) = content else {
            return XCTFail("expected .failed, got \(content)")
        }
        XCTAssertTrue(error.contains("5 MB"))
    }

    // MARK: - parseMediaResponse

    func test_parseMediaResponse_audioWithRelativeMediaUrl() {
        let content = RemoteFileContentFetcher.parseMediaResponse(textResponse(
            kind: "audio",
            mediaUrl: "/api/media/abc123",
            mimeType: "audio/mpeg",
            sizeBytes: 5678
        ), httpBaseURL: URL(string: "http://192.168.1.10:8766"))
        guard case .audio(let url, let mime, let size) = content else {
            return XCTFail("expected .audio, got \(content)")
        }
        XCTAssertEqual(url.absoluteString, "http://192.168.1.10:8766/api/media/abc123")
        XCTAssertEqual(mime, "audio/mpeg")
        XCTAssertEqual(size, 5678)
    }

    func test_parseMediaResponse_videoWithWssDerivedHttp() {
        // wss:// 派生 https://（RemoteFileContentFetcher.absoluteMediaURL 规则）
        let url = RemoteFileContentFetcher.absoluteMediaURL(
            relative: "/api/media/vid1",
            httpBaseURL: URL(string: "https://host:8766")
        )
        XCTAssertEqual(url?.absoluteString, "https://host:8766/api/media/vid1")
    }

    func test_parseMediaResponse_errorTakesPriority() {
        let content = RemoteFileContentFetcher.parseMediaResponse(textResponse(
            kind: "video",
            mediaUrl: "/api/media/x",
            error: "Media preview is unavailable on this Bridge."
        ), httpBaseURL: URL(string: "http://h:1"))
        guard case .failed(let error) = content else {
            return XCTFail("expected .failed, got \(content)")
        }
        XCTAssertTrue(error.contains("unavailable"))
    }

    func test_parseMediaResponse_missingMediaUrl_fails() {
        let content = RemoteFileContentFetcher.parseMediaResponse(
            textResponse(kind: "video"),
            httpBaseURL: URL(string: "http://h:1")
        )
        guard case .failed = content else {
            return XCTFail("expected .failed, got \(content)")
        }
    }

    // MARK: - isMediaFile

    func test_isMediaFile_audioAndVideo() {
        XCTAssertTrue(RemoteFileContentFetcher.isMediaFile(path: "demo.mp4"))
        XCTAssertTrue(RemoteFileContentFetcher.isMediaFile(path: "song.mp3"))
        XCTAssertTrue(RemoteFileContentFetcher.isMediaFile(path: "/abs/path/clip.mov"))
    }

    func test_isMediaFile_textAndImageAreNotMedia() {
        XCTAssertFalse(RemoteFileContentFetcher.isMediaFile(path: "foo.swift"))
        XCTAssertFalse(RemoteFileContentFetcher.isMediaFile(path: "pic.png"))
        XCTAssertFalse(RemoteFileContentFetcher.isMediaFile(path: "README.md"))
        XCTAssertFalse(RemoteFileContentFetcher.isMediaFile(path: "noext"))
    }
}
