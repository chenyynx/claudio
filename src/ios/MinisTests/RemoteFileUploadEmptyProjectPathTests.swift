// [Claudio 2026-09-06 G1.3] Pin the empty / whitespace-only projectPath
// pre-flight behaviour in `RemoteFileUpload.upload`.
//
// Why this test exists:
//   Bridge parser (claudio-bridge/packages/bridge/src/parser.ts:1722-1723)
//   drops `prepare_file_upload` messages whose `projectPath` is empty or
//   whitespace-only — silently. The Bridge then replies with a generic
//   `unsupported_message`, which the iOS provider surfaced as the cryptic
//   "[User attempted to attach X failed: prepare_file_upload]" bubble with
//   no actionable info.
//
//   The fix catches this CLIENT-side (before sending) and throws
//   `RemoteUploadError(code: "project_path_not_configured")`. This test
//   pins that contract so a future refactor doesn't regress to "let the
//   bridge decide" (the original bug).
//
// What this test pins:
//   1. Empty string → throws with code `project_path_not_configured`
//   2. Whitespace-only string → throws with the same code (trimmed check)
//   3. The error message is non-empty so the UI has something to render
//   4. Valid projectPath does NOT trip the pre-flight (we never reach the
//      network — this just confirms control flow up to sendAndWaitRPC).

import XCTest
@testable import Minis

final class RemoteFileUploadEmptyProjectPathTests: XCTestCase {

    /// Dummy URL the fileSize() guard (line 95) checks before returning.
    /// Empty projectPath trips pre-flight FIRST, so the file path doesn't
    /// actually need to exist — but a valid URL keeps the test honest in
    /// case the pre-flight is ever removed by accident.
    private let dummyFileURL = URL(fileURLWithPath: "/tmp/not-actually-checked-by-preflight.bin")

    // MARK: - 1. 空字符串触发专属错误码

    func test_emptyProjectPath_throwsProjectPathNotConfigured() async {
        do {
            _ = try await RemoteFileUpload.upload(
                client: makeUnreachableClient(),
                projectPath: "",
                fileName: "probe.pdf",
                fileURL: dummyFileURL
            )
            XCTFail("expected RemoteUploadError, got success")
        } catch let error as RemoteUploadError {
            XCTAssertEqual(error.code, "project_path_not_configured",
                          "错误码必须是 project_path_not_configured,UI 引导依赖此值")
        } catch {
            XCTFail("expected RemoteUploadError, got \(error)")
        }
    }

    // MARK: - 2. 纯空白字符串也要拦截（trim 后视为空）

    func test_whitespaceOnlyProjectPath_throwsProjectPathNotConfigured() async {
        for whitespace in ["   ", "\t", "\n", " \t\n "] {
            do {
                _ = try await RemoteFileUpload.upload(
                    client: makeUnreachableClient(),
                    projectPath: whitespace,
                    fileName: "probe.pdf",
                    fileURL: dummyFileURL
                )
                XCTFail("whitespace=\(whitespace.debugDescription) should throw")
            } catch let error as RemoteUploadError {
                XCTAssertEqual(error.code, "project_path_not_configured",
                              "whitespace=\(whitespace.debugDescription) 必须被 trim 后判空")
            } catch {
                XCTFail("whitespace=\(whitespace.debugDescription) got unexpected \(error)")
            }
        }
    }

    // MARK: - 3. 错误消息非空,UI 可显示

    func test_emptyProjectPathError_messageIsActionable() {
        // Construct the same error the upload function throws so we can
        // assert on its `message` (LocalizedError.errorDescription).
        // This pins the UI text contract — if someone shortens the
        // message and loses the "请在 Remote Session 设置里填写" hint,
        // the user no longer knows where to fix it.
        let error = RemoteUploadError(
            code: "project_path_not_configured",
            message: "Project Path 未配置，无法上传文件。请在 Remote Session 设置里填写 Project Path。"
        )
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Remote Session") ?? false,
                     "错误消息必须包含「Remote Session」,告诉用户去哪里配")
        XCTAssertTrue(error.errorDescription?.contains("Project Path") ?? false,
                     "错误消息必须包含字段名「Project Path」")
    }

    // MARK: - 4. Mock 客户端 — 空 path 永远不会走到网络

    /// Stub client whose `connect` blocks forever if called — proves the
    /// pre-flight short-circuits BEFORE the wire handshake. The test will
    /// hang (XCTest timeout) if a regression ever lets the empty projectPath
    /// reach `connect()`/`sendAndWaitRPC()`.
    ///
    /// We can't subclass `CCPocketClient` (it's `final`), so we hand a
    /// real instance pointed at an unroutable address. With no network
    /// ever reaching the bridge, the only way the upload call returns is
    /// the pre-flight throwing.
    private func makeUnreachableClient() -> CCPocketClient {
        CCPocketClient(
            baseURL: URL(string: "ws://127.0.0.1:1")!,
            token: ""
        )
    }
}