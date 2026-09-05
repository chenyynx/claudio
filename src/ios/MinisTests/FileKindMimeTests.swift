// [Claudio 2026-09-06] Pin FileKind mime 推断 + 扩展名推断契约。
//
// 卡片 1:1 复刻 Claude 样式（FileAttachmentCard.swift）的根基：
// 5 种文件类型分组 (.document / .code / .image / .video / .audio) + .file 兜底。
// 任何 mime/扩展名分错 → 卡片图标方块色错（5 色 + 灰兜底）→ 用户体验崩。
//
// 矩阵（pp 拍板，按 fileType 分组）：
//   - image/*            → .image  (photo 图标 + 紫底)
//   - video/*            → .video  (play.rectangle 图标 + 绿底)
//   - audio/*            → .audio  (music.note 图标 + 橙底)
//   - text/x-python 等   → .code   (chevron 图标 + 黄底)
//   - text/plain/md/xml  → .document (doc.text 图标 + 蓝底)
//   - application/pdf    → .document
//   - application/json   → .code
//   - 未知 mime → fallback 扩展名
//   - 未知扩展名 → .file (灰底 + doc 图标)

import XCTest
@testable import Minis

final class FileKindMimeTests: XCTestCase {

    // MARK: - mime 推断：image / video / audio

    func test_mime_imagePrefix_returnsImage() {
        XCTAssertEqual(FileKind.from(mimeType: "image/png", fileName: "x"), .image)
        XCTAssertEqual(FileKind.from(mimeType: "image/jpeg", fileName: "x"), .image)
        XCTAssertEqual(FileKind.from(mimeType: "image/heic", fileName: "x"), .image)
        XCTAssertEqual(FileKind.from(mimeType: "image/webp", fileName: "x"), .image)
        XCTAssertEqual(FileKind.from(mimeType: "image/svg+xml", fileName: "x"), .image)
    }

    func test_mime_videoPrefix_returnsVideo() {
        XCTAssertEqual(FileKind.from(mimeType: "video/mp4", fileName: "x"), .video)
        XCTAssertEqual(FileKind.from(mimeType: "video/quicktime", fileName: "x"), .video)
        XCTAssertEqual(FileKind.from(mimeType: "video/webm", fileName: "x"), .video)
    }

    func test_mime_audioPrefix_returnsAudio() {
        XCTAssertEqual(FileKind.from(mimeType: "audio/mpeg", fileName: "x"), .audio)
        XCTAssertEqual(FileKind.from(mimeType: "audio/wav", fileName: "x"), .audio)
        XCTAssertEqual(FileKind.from(mimeType: "audio/x-m4a", fileName: "x"), .audio)
    }

    // MARK: - mime 推断：text/* 细分 code vs document

    func test_mime_textCodeHints_returnsCode() {
        // ccpocket 推 text/x-python / text/x-swift 等带语言名的 mime
        let codeMimes = [
            "text/x-python", "text/x-swift", "text/javascript", "text/typescript",
            "text/x-rust", "text/x-java", "text/x-ruby", "text/x-go",
            "text/x-kotlin", "text/x-c++hdr", "text/x-perl", "text/x-php",
            "text/x-scala", "text/html", "text/css", "text/x-shellscript",
        ]
        for mime in codeMimes {
            XCTAssertEqual(FileKind.from(mimeType: mime, fileName: "x"),
                          .code, "mime=\(mime) should map to .code")
        }
    }

    func test_mime_textPlainMarkdown_returnsDocument() {
        // 纯文本/标记类走 .document（不带代码高亮）
        XCTAssertEqual(FileKind.from(mimeType: "text/plain", fileName: "x"), .document)
        XCTAssertEqual(FileKind.from(mimeType: "text/markdown", fileName: "x"), .document)
        XCTAssertEqual(FileKind.from(mimeType: "text/xml", fileName: "x"), .document)
    }

    // MARK: - mime 推断：application/* 细分

    func test_mime_applicationPdf_returnsDocument() {
        XCTAssertEqual(FileKind.from(mimeType: "application/pdf", fileName: "x"), .document)
    }

    func test_mime_applicationOffice_returnsDocument() {
        XCTAssertEqual(FileKind.from(mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileName: "x"), .document)
        XCTAssertEqual(FileKind.from(mimeType: "application/msword", fileName: "x"), .document)
    }

    func test_mime_applicationJsonYaml_returnsCode() {
        XCTAssertEqual(FileKind.from(mimeType: "application/json", fileName: "x"), .code)
        XCTAssertEqual(FileKind.from(mimeType: "application/xml", fileName: "x"), .code)
        XCTAssertEqual(FileKind.from(mimeType: "application/yaml", fileName: "x"), .code)
    }

    // MARK: - mime 推断：unknown mime → fallback 扩展名

    func test_mime_octetStream_fallsBackToExtension() {
        // application/octet-stream 是常见兜底 mime，不能直接 .file 兜底
        XCTAssertEqual(
            FileKind.from(mimeType: "application/octet-stream", fileName: "x.py"),
            .code
        )
        XCTAssertEqual(
            FileKind.from(mimeType: "application/octet-stream", fileName: "x.png"),
            .image
        )
    }

    func test_mime_empty_fallsBackToExtension() {
        XCTAssertEqual(FileKind.from(mimeType: "", fileName: "x.md"), .document)
        XCTAssertEqual(FileKind.from(mimeType: nil, fileName: "x.swift"), .code)
    }

    // MARK: - 扩展名 fallback（独立测，ccpocket bridge 不给 mime 时靠扩展名）

    func test_extension_codeLanguages() {
        let codeExts = ["py", "swift", "js", "ts", "jsx", "tsx",
                        "html", "css", "json", "yaml", "yml",
                        "sh", "rs", "go", "java", "kt", "c", "cpp", "h"]
        for ext in codeExts {
            XCTAssertEqual(FileKind.fromExtension(ext), .code,
                           "ext=\(ext) should map to .code")
        }
    }

    func test_extension_documents() {
        XCTAssertEqual(FileKind.fromExtension("md"), .document)
        XCTAssertEqual(FileKind.fromExtension("markdown"), .document)
        XCTAssertEqual(FileKind.fromExtension("txt"), .document)
        XCTAssertEqual(FileKind.fromExtension("pdf"), .document)
        XCTAssertEqual(FileKind.fromExtension("csv"), .document)
    }

    func test_extension_images() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"] {
            XCTAssertEqual(FileKind.fromExtension(ext), .image,
                           "ext=\(ext) should map to .image")
        }
    }

    func test_extension_videos() {
        for ext in ["mp4", "mov", "m4v", "webm", "mkv"] {
            XCTAssertEqual(FileKind.fromExtension(ext), .video,
                           "ext=\(ext) should map to .video")
        }
    }

    func test_extension_audios() {
        for ext in ["mp3", "m4a", "wav", "flac", "ogg", "opus"] {
            XCTAssertEqual(FileKind.fromExtension(ext), .audio,
                           "ext=\(ext) should map to .audio")
        }
    }

    func test_extension_unknown_returnsFileFallback() {
        XCTAssertEqual(FileKind.fromExtension("xyz"), .file)
        XCTAssertEqual(FileKind.fromExtension(""), .file)
    }

    // MARK: - mime 推断：大小写不敏感

    func test_mime_caseInsensitive() {
        // ccpocket / 不同 OS 返回的 mime 大小写不一致
        XCTAssertEqual(FileKind.from(mimeType: "IMAGE/PNG", fileName: "x"), .image)
        XCTAssertEqual(FileKind.from(mimeType: "Application/PDF", fileName: "x"), .document)
    }

    // MARK: - typeLabel 自检（i18n 完整性）

    func test_typeLabel_allCases_haveNonEmptyEnglish() {
        // 兜底：兜底类型也应有标签（避免 UI 显示 "Type · Type"）
        XCTAssertFalse(FileKind.document.typeLabel.isEmpty)
        XCTAssertFalse(FileKind.code.typeLabel.isEmpty)
        XCTAssertFalse(FileKind.image.typeLabel.isEmpty)
        XCTAssertFalse(FileKind.video.typeLabel.isEmpty)
        XCTAssertFalse(FileKind.audio.typeLabel.isEmpty)
        XCTAssertFalse(FileKind.file.typeLabel.isEmpty)
    }
}
