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
    static func upload(
        client: CCPocketClient,
        projectPath: String,
        directoryPath: String = ".",
        fileName: String,
        fileURL: URL,
        conflictPolicy: String = "keepBoth"
    ) async throws -> RemoteUploadResult {
        let sizeBytes = try fileSize(fileURL)

        // ── 1. prepare ──
        let prepareReq: [String: Any] = [
            "type": "prepare_file_upload",
            "projectPath": projectPath,
            "directoryPath": directoryPath,
            "fileName": fileName,
            "sizeBytes": sizeBytes,
            "conflictPolicy": conflictPolicy,
            "requestId": UUID().uuidString,
        ]
        let prepare = try await client.sendAndWaitRPC(prepareReq)
        guard let uploadUrlStr = prepare["uploadUrl"] as? String,
              let uploadToken = prepare["uploadToken"] as? String,
              let url = URL(string: uploadUrlStr) else {
            throw RemoteUploadError(
                code: (prepare["errorCode"] as? String) ?? "file_upload_failed",
                message: (prepare["message"] as? String) ?? "prepare_file_upload returned no upload URL"
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
        let finalName = (finalize["fileName"] as? String) ?? fileName
        let finalSize = (finalize["sizeBytes"] as? Int) ?? sizeBytes
        return RemoteUploadResult(fileName: finalName, sizeBytes: finalSize, sha256: sha256)
    }

    // MARK: - helpers

    private static func fileSize(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    /// HTTP PUT 文件（URLSession fromFile 零内存）+ 分块流式 SHA-256。
    private static func httpPutAndHash(url: URL, fileURL: URL) async throws -> String {
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteUploadError(code: "file_upload_http_failed",
                                     message: "Upload HTTP request failed")
        }
        return hex
    }
}
