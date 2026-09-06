import Foundation
import CryptoKit

// MARK: - 远端文件上传（Claude Code bridge 项目目录）
//
// 照搬 ccpocket bridge 协议（~/refs/ccpocket-main/packages/bridge/src/websocket.ts）：
// prepare_file_upload → HTTP PUT 上传到 token URL → finalize_file_upload。
// App 侧只做协议封装+SHA-256 流式校验，不改 UI。

struct RemoteUploadError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct RemoteUploadResult {
    let fileName: String
    let sizeBytes: Int
    let sha256: String
}


final class RemoteFileUpload {

    /// 完整上传一个文件到 bridge 项目目录；返回结果或抛 RemoteUploadError。
    ///
    /// [Claudio 2026-09-06 G1] Pre-flight 校验 projectPath 非空：bridge parser
    /// 把空 projectPath 当 unsupported_message 直接 drop，UI 端只能看到
    /// `[User attempted to attach X failed: prepare_file_upload]` 这种
    /// 不可执行的错误。提前在客户端拦截，让上游能看到具体错误码
    /// `project_path_not_configured`，UI 层可以引导用户去设置。
    static func upload(
        client: CCPocketClient,
        projectPath: String,
        directoryPath: String = ".",
        fileName: String,
        fileURL: URL,
        conflictPolicy: String = "rename"
    ) async throws -> RemoteUploadResult {
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw RemoteUploadError(
                code: "project_path_not_configured",
                message: "Project Path 未配置，无法上传文件。请在 Remote Session 设置里填写 Project Path。"
            )
        }
        let sizeBytes = try fileSize(fileURL)

        // ── 1. prepare ──
        let prepareReq: [String: Any] = [
            "type": "prepare_file_upload",
            "projectPath": trimmedPath,
            "directoryPath": directoryPath,
            "fileName": fileName,
            "sizeBytes": sizeBytes,
            "conflictPolicy": conflictPolicy,
            "requestId": UUID().uuidString,
        ]
        DiagnosticsLog.shared.write(
            "RemoteFileUpload",
            "prepare-req type=\(prepareReq["type"] ?? "?") projectPath=\"\(trimmedPath)\" directoryPath=\"\(directoryPath)\" fileName=\"\(fileName)\" sizeBytes=\(sizeBytes) (type=\(type(of: sizeBytes))) conflictPolicy=\"\(conflictPolicy)\" requestId=\"\(prepareReq["requestId"] ?? "?")\" fileURL=\(fileURL.path)"
        )
        let prepare = try await client.sendAndWaitRPC(prepareReq)
        DiagnosticsLog.shared.write("RemoteFileUpload", "prepare-resp \(prepare)")
        guard let uploadUrlStr = prepare["uploadUrl"] as? String,
              let uploadToken = prepare["uploadToken"] as? String else {
            throw RemoteUploadError(
                code: (prepare["errorCode"] as? String) ?? "file_upload_failed",
                message: (prepare["message"] as? String) ?? "prepare_file_upload returned no upload URL"
            )
        }
        // [Claudio 2026-09-06] 桥 upload-store.ts:224 返回相对路径
        // `/api/uploads/<token>`（无 scheme/host）。直接 URL(string:)
        // 构造会让 URLSession.upload 抛 NSURLErrorUnsupportedURL（iOS
        // 中文翻译「不支持的URL」），上传卡 HTTP PUT 阶段，前几轮
        // 修复全在 prepare 阶段，没碰到这里。用 client.httpBaseURL
        // 派生 http://host:port 拼绝对 URL（RemoteFileContentFetcher
        // 处理 /api/media/<id> 同款路径，CCPocketClient.swift:1415
        // 已实现 ws→http scheme 切换）。若桥后续返回绝对 URL，路径
        // 分支的 scheme 守卫让它走原路径。
        let url: URL
        if let parsed = URL(string: uploadUrlStr), parsed.scheme != nil {
            url = parsed
        } else if let base = client.httpBaseURL,
                  let composed = URL(string: uploadUrlStr, relativeTo: base)?.absoluteURL {
            DiagnosticsLog.shared.write(
                "RemoteFileUpload",
                "url-rewrite relative=\"\(uploadUrlStr)\" base=\"\(base.absoluteString)\" → \"\(composed.absoluteString)\""
            )
            url = composed
        } else {
            throw RemoteUploadError(
                code: "file_upload_invalid_url",
                message: "prepare_file_upload returned unsupported uploadUrl (no host / no httpBaseURL): \(uploadUrlStr)"
            )
        }

        // ── 2. HTTP PUT（fromFile 零内存）+ 流式 SHA-256 ──
        let sha256 = try await httpPutAndHash(url: url, fileURL: fileURL)

        // ── 3. finalize ──
        let finalizeReq: [String: Any] = [
            "type": "finalize_file_upload",
            "uploadToken": uploadToken,
            "sha256": sha256,
            "requestId": UUID().uuidString,
        ]
        let finalize = try await client.sendAndWaitRPC(finalizeReq)
        DiagnosticsLog.shared.write("RemoteFileUpload", "finalize-resp \(finalize)")
        let finalName = (finalize["fileName"] as? String) ?? fileName
        let finalSize = (finalize["sizeBytes"] as? Int) ?? sizeBytes
        DiagnosticsLog.shared.write(
            "RemoteFileUpload",
            "upload-ok fileName=\(finalName) sizeBytes=\(finalSize) (type=\(type(of: finalSize))) sha256=\(String(sha256.prefix(8)))"
        )
        return RemoteUploadResult(fileName: finalName, sizeBytes: finalSize, sha256: sha256)
    }

    // MARK: - helpers

    private static func fileSize(_ url: URL) throws -> Int {
        // Last-line defence: the local cache path may have been reaped between
        // `addFileAttachment` and this call. Surface a precise re-add hint
        // instead of the cryptic NSCocoaError "file doesn't exist".
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            DiagnosticsLog.shared.write("RemoteFileUpload", "fileSize-miss path=\(url.path) exists=\(exists)")
            throw RemoteUploadError(
                code: "file_not_found_re_add",
                message: "附件文件不存在：\(url.lastPathComponent)。请重新选择附件后再发送。"
            )
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    /// HTTP PUT 文件（URLSession fromFile 零内存）+ 分块流式 SHA-256。
    private static func httpPutAndHash(url: URL, fileURL: URL) async throws -> String {
        // Same last-line guard as fileSize — SHA-256 read + URLSession upload
        // both need a real file on disk.
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        guard exists else {
            DiagnosticsLog.shared.write("RemoteFileUpload", "httpPut-miss path=\(fileURL.path) exists=\(exists)")
            throw RemoteUploadError(
                code: "file_not_found_re_add",
                message: "附件文件不存在：\(fileURL.lastPathComponent)。请重新选择附件后再发送。"
            )
        }
        // SHA-256 流式
        var sha = SHA256()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let chunkSize = 64 * 1024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            sha.update(data: chunk)
        }
        let hex = sha.finalize().map { String(format: "%02x", $0) }.joined()

        // HTTP PUT
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            DiagnosticsLog.shared.write("RemoteFileUpload", "httpPut-fail status=\(statusCode)")
            throw RemoteUploadError(code: "file_upload_http_failed",
                                     message: "Upload HTTP request failed (status=\(statusCode))")
        }
        return hex
    }
}
