import Foundation

// MARK: - 远端文件下载（Claude Code bridge 项目目录）
//
// 照搬 ccpocket bridge 协议（~/refs/ccpocket-main/packages/bridge/src/websocket.ts:1076-1205）：
// prepare_file_download → HTTP GET 一次性 token URL → 返回本地路径。
// 与 RemoteFileUpload 对称（pre/upload vs pre/download），无 finalize 步骤。
//
// **App 端不做 UI、不持状态**——只做协议封装 + 路径转换 + HTTP 下载 + 落盘。
// 状态机（idle/preparing/downloading/ready/failed）和 AssistantBlock 字段
// 写入由调用方（RemoteFileDownloadCoordinator）驱动，保持本类无副作用。

struct RemoteDownloadError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct RemoteDownloadResult {
    let localPath: String       // iOS 沙箱绝对路径（Library/Caches/codios-downloads/...）
    let fileName: String
    let sizeBytes: Int64
    let mimeType: String?
}


/// [Claudio 2026-09-05] Download a file the remote agent produced. Aligned with
/// ccpocket's `prepareFileDownload` (websocket.ts:1076-1205). Steps:
///   1. Convert absolute bridge-host path to **project-relative** (bridge
///      rejects absolute paths at websocket.ts:1082-1090).
///   2. Send `prepare_file_download` via CCPocketClient.sendAndWaitRPC.
///      Bridge validates: project boundary, realpath, regular file, size limit,
///      mediaStore availability (websocket.ts:1082-1190). On any failure, replies
///      with `error` carrying one of 6 error codes (FileDownloadErrorCode).
///   3. HTTP GET the returned `downloadUrl` (one-shot token) — no PUT, no
///      finalize. Stream bytes to iOS sandbox `Library/Caches/codios-downloads/`.
final class RemoteFileDownload {

    /// Download a file to iOS sandbox. Throws RemoteDownloadError on any failure.
    /// - Parameters:
    ///   - client: CCPocketClient (must be connected)
    ///   - projectPath: bridge projectPath (e.g. "/home/ubuntu/myapp")
    ///   - absFilePath: absolute path on bridge host (from AssistantBlock.outputFileRemotePath)
    ///   - suggestedFileName: override for downloaded filename; defaults to absFilePath's basename
    static func download(
        client: CCPocketClient,
        projectPath: String,
        absFilePath: String,
        suggestedFileName: String? = nil,
        suggestedMimeType: String? = nil
    ) async throws -> RemoteDownloadResult {
        // ── 1. abs → project-relative ──
        let relPath = try absToRel(projectPath: projectPath, absPath: absFilePath)
        let fileName = suggestedFileName ?? (absFilePath as NSString).lastPathComponent

        // ── 2. prepare_file_download ──
        let prepareReq: [String: Any] = [
            "type": "prepare_file_download",
            "projectPath": projectPath,
            "filePath": relPath,
            "requestId": UUID().uuidString,
        ]
        let prepare = try await client.sendAndWaitRPC(prepareReq)
        // [Fix 2026-09-05] 对齐 ccpocket websocket.ts:1197-1205 file_download_ready
        // shape: downloadUrl + fileName + mimeType + sizeBytes + filePath.
        guard let urlStr = prepare["downloadUrl"] as? String,
              let url = URL(string: urlStr) else {
            throw RemoteDownloadError(
                code: (prepare["errorCode"] as? String)
                    ?? CCPocketProtocol.FileDownloadErrorCode.failed.rawValue,
                message: (prepare["message"] as? String)
                    ?? "prepare_file_download returned no downloadUrl"
            )
        }
        let mime = (prepare["mimeType"] as? String) ?? suggestedMimeType
        let sizeBytes = (prepare["sizeBytes"] as? Int64) ?? 0
        let readyFileName = (prepare["fileName"] as? String) ?? fileName

        // ── 3. HTTP GET to sandbox ──
        let destURL = try await httpGetToSandbox(
            downloadURL: url,
            fileName: readyFileName
        )
        return RemoteDownloadResult(
            localPath: destURL.path,
            fileName: readyFileName,
            sizeBytes: sizeBytes,
            mimeType: mime
        )
    }

    // MARK: - helpers

    /// Convert `/home/ubuntu/proj/sub/x.py` + `/home/ubuntu/proj` → `sub/x.py`.
    /// Bridge rejects absolute paths; we must relativize.
    /// Throws RemoteDownloadError(.notAllowed) if absPath is outside projectPath.
    static func absToRel(projectPath: String, absPath: String) throws -> String {
        // Normalize: ensure projectPath has no trailing slash (except root)
        let proj = projectPath.hasSuffix("/") && projectPath.count > 1
            ? String(projectPath.dropLast())
            : projectPath
        // Must start with projectPath + "/"
        let prefix = proj + "/"
        guard absPath.hasPrefix(prefix) else {
            throw RemoteDownloadError(
                code: CCPocketProtocol.FileDownloadErrorCode.notAllowed.rawValue,
                message: "File '\(absPath)' is outside project '\(proj)'. " +
                         "Bridge only allows project-relative paths (websocket.ts:1082-1090)."
            )
        }
        let rel = String(absPath.dropFirst(prefix.count))
        // Reject path traversal — bridge will reject too, fail fast.
        if rel.contains("..") {
            throw RemoteDownloadError(
                code: CCPocketProtocol.FileDownloadErrorCode.notAllowed.rawValue,
                message: "Path '\(rel)' contains '..'; bridge rejects traversal."
            )
        }
        return rel
    }

    /// HTTP GET the one-shot downloadUrl, write to iOS sandbox
    /// `Library/Caches/codios-downloads/{requestId}/{fileName}`. Returns dest URL.
    private static func httpGetToSandbox(downloadURL: URL, fileName: String) async throws -> URL {
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        // data(for:) — iOS 15+, simple; no progress callback (state-machine callers
        // show a generic "downloading" spinner via AssistantBlock.outputFileDownloadState).
        // Progress bar can be added later via bytes(for:) if needed.
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = CCPocketProtocol.FileDownloadErrorCode.failed.rawValue
            throw RemoteDownloadError(
                code: code,
                message: "Download HTTP request failed (status=\(responseStatus(response)))"
            )
        }
        let dir = try sandboxDownloadDir()
        let destURL = dir.appendingPathComponent(fileName)
        try data.write(to: destURL, options: .atomic)
        return destURL
    }

    private static func responseStatus(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// Library/Caches/codios-downloads/ (system can purge; non-user-data files).
    private static func sandboxDownloadDir() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = caches.appendingPathComponent("codios-downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
