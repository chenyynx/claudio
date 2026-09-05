// [Claudio 2026-09-06] Pin RemoteFileDownload absToRel 转换契约。
//
// 协议核心约束（ccpocket bridge/src/websocket.ts:1082-1090）：
//   - bridge 拒绝绝对路径，只接受 projectPath 内相对路径
//   - 任何 abs→rel 转换错误 = download 直接失败（HTTP 400 from bridge）
//   - 路径穿越（".."）必须被 App 端拦截，bridge 也再拦一次（fail-fast）
//
// 测试覆盖：
//   1. abs 在 projectPath 内 → 成功转 rel
//   2. abs 在 projectPath 外 → throws .notAllowed
//   3. abs = projectPath 本身（边界）→ 抛 .notAllowed（用户用 prepare_file_download 传目录无效）
//   4. rel 含 ".." → 抛 .notAllowed
//   5. projectPath 有/无尾斜杠 → 两种都正常处理
//   6. abs 是 projectPath 嵌套子目录 → 正常转 rel（保留中间路径）
//   7. RemoteDownloadError .code 字段映射 ccpocket 6 个错误码
//
// 注：download() 整体（含 HTTP/WS）不在本测试范围 — 需要 mock CCPocketClient，
//      留给 future PR。absToRel 是纯函数，先 pin 死契约。

import XCTest
@testable import Minis

final class RemoteFileDownloadTests: XCTestCase {

    // MARK: - 正向：abs → rel 成功

    func test_absToRel_topLevelFile_succeeds() {
        let rel = try? RemoteFileDownload.absToRel(
            projectPath: "/home/ubuntu/proj",
            absPath: "/home/ubuntu/proj/main.py"
        )
        XCTAssertEqual(rel, "main.py")
    }

    func test_absToRel_nestedDir_succeeds() {
        let rel = try? RemoteFileDownload.absToRel(
            projectPath: "/home/ubuntu/proj",
            absPath: "/home/ubuntu/proj/src/utils/helper.py"
        )
        XCTAssertEqual(rel, "src/utils/helper.py")
    }

    func test_absToRel_projectPathWithTrailingSlash_succeeds() {
        // 工程实际存 projectPath 时可能带尾斜杠，转换器要兼容
        let rel = try? RemoteFileDownload.absToRel(
            projectPath: "/home/ubuntu/proj/",
            absPath: "/home/ubuntu/proj/main.py"
        )
        XCTAssertEqual(rel, "main.py")
    }

    func test_absToRel_rootProject_works() {
        // projectPath = "/" 边界（虽然实际不常见，pin 一下）
        let rel = try? RemoteFileDownload.absToRel(
            projectPath: "/",
            absPath: "/main.py"
        )
        XCTAssertEqual(rel, "main.py")
    }

    // MARK: - 反向：abs 在 projectPath 外 → 抛 .notAllowed

    func test_absToRel_outsideProject_throwsNotAllowed() {
        XCTAssertThrowsError(
            try RemoteFileDownload.absToRel(
                projectPath: "/home/ubuntu/proj",
                absPath: "/etc/passwd"
            )
        ) { error in
            guard let err = error as? RemoteDownloadError else {
                XCTFail("expected RemoteDownloadError, got \(error)")
                return
            }
            XCTAssertEqual(
                err.code,
                CCPocketProtocol.FileDownloadErrorCode.notAllowed.rawValue
            )
        }
    }

    func test_absToRel_siblingProject_throwsNotAllowed() {
        // /home/ubuntu/proj2 是 /home/ubuntu/proj 的兄弟目录
        XCTAssertThrowsError(
            try RemoteFileDownload.absToRel(
                projectPath: "/home/ubuntu/proj",
                absPath: "/home/ubuntu/proj2/main.py"
            )
        ) { error in
            guard let err = error as? RemoteDownloadError else {
                XCTFail("expected RemoteDownloadError")
                return
            }
            XCTAssertEqual(
                err.code,
                CCPocketProtocol.FileDownloadErrorCode.notAllowed.rawValue,
                "兄弟目录不应被允许（前缀匹配必须带 '/' 边界）"
            )
        }
    }

    func test_absToRel_projectPathItself_throwsNotAllowed() {
        // 边界：abs = projectPath（用户传目录而非文件）
        XCTAssertThrowsError(
            try RemoteFileDownload.absToRel(
                projectPath: "/home/ubuntu/proj",
                absPath: "/home/ubuntu/proj"
            )
        ) { error in
            guard let err = error as? RemoteDownloadError else {
                XCTFail("expected RemoteDownloadError")
                return
            }
            XCTAssertEqual(
                err.code,
                CCPocketProtocol.FileDownloadErrorCode.notAllowed.rawValue
            )
        }
    }

    // MARK: - 路径穿越防御

    func test_absToRel_pathTraversal_throwsNotAllowed() {
        // 即使 abs 在 projectPath 内，rel 含 ".." 也必须 fail-fast
        XCTAssertThrowsError(
            try RemoteFileDownload.absToRel(
                projectPath: "/home/ubuntu/proj",
                absPath: "/home/ubuntu/proj/subdir/../escape.py"
            )
        ) { error in
            guard let err = error as? RemoteDownloadError else {
                XCTFail("expected RemoteDownloadError")
                return
            }
            XCTAssertEqual(
                err.code,
                CCPocketProtocol.FileDownloadErrorCode.notAllowed.rawValue
            )
        }
    }

    // MARK: - FileDownloadState 状态机

    func test_downloadState_isFailed_correctDetection() {
        XCTAssertFalse(FileDownloadState.idle.isFailed)
        XCTAssertFalse(FileDownloadState.preparing.isFailed)
        XCTAssertFalse(FileDownloadState.downloading(progress: 0.5).isFailed)
        XCTAssertFalse(FileDownloadState.ready(localPath: "/x").isFailed)
        XCTAssertTrue(
            FileDownloadState.failed(
                errorCode: "file_download_failed",
                message: "x"
            ).isFailed
        )
    }

    func test_downloadState_equatable() {
        // 状态机 case Equatable — Card UI 比较状态用
        XCTAssertEqual(
            FileDownloadState.downloading(progress: 0.5),
            FileDownloadState.downloading(progress: 0.5)
        )
        XCTAssertNotEqual(
            FileDownloadState.downloading(progress: 0.5),
            FileDownloadState.downloading(progress: 0.6)
        )
        XCTAssertEqual(
            FileDownloadState.ready(localPath: "/a"),
            FileDownloadState.ready(localPath: "/a")
        )
        XCTAssertNotEqual(
            FileDownloadState.ready(localPath: "/a"),
            FileDownloadState.ready(localPath: "/b")
        )
    }

    // MARK: - FileDownloadErrorCode 6 个 case 完整性

    func test_fileDownloadErrorCode_allSixCodes_present() {
        // ccpocket websocket.ts:1184-1190 定义的 6 个错误码必须全在
        let allCodes: [CCPocketProtocol.FileDownloadErrorCode] = [
            .notAllowed, .notFound, .notFile, .tooLarge, .unavailable, .failed,
        ]
        XCTAssertEqual(allCodes.count, 6)
        // 原始字符串值匹配 ccpocket 协议文档
        XCTAssertEqual(CCPocketProtocol.FileDownloadErrorCode.notAllowed.rawValue, "file_download_not_allowed")
        XCTAssertEqual(CCPocketProtocol.FileDownloadErrorCode.notFound.rawValue, "file_download_not_found")
        XCTAssertEqual(CCPocketProtocol.FileDownloadErrorCode.notFile.rawValue, "file_download_not_file")
        XCTAssertEqual(CCPocketProtocol.FileDownloadErrorCode.tooLarge.rawValue, "file_download_too_large")
        XCTAssertEqual(CCPocketProtocol.FileDownloadErrorCode.unavailable.rawValue, "file_download_unavailable")
        XCTAssertEqual(CCPocketProtocol.FileDownloadErrorCode.failed.rawValue, "file_download_failed")
    }
}
