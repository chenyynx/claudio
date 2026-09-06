//
//  RemoteFileContent.swift
//  MinisApp
//
//  远端文件内容读取封装（ccpocket file_peek 数据层）。
//
//  对齐 ccpocket 官方：
//  - apps/mobile/lib/features/file_peek/file_peek_sheet.dart
//    ClientMessage.readFile / readMediaFile + BridgeService.fileContent.listen
//  - packages/bridge/src/websocket.ts:5930 `read_file` / `read_media_file` +
//    `file_content` 回包
//  - packages/bridge/src/media-store.ts:143 `mediaUrl = "/api/media/<id>"`
//
//  与 RemoteFileDownload（9a844c3）的关系：
//  - RemoteFileDownload = 「下载整文件落本地 cache」+ FilePreviewPanel
//    已落盘 UI，用于「agent 写完文件让用户保存到本地」语义。
//  - RemoteFileContent = 「按需读」+ RemoteFilePeekSheet 不落盘 UI，
//    用于「正文路径点击预览」语义——文本走 content 字符串秒开、媒体走
//    mediaUrl HTTP 流式。
//  两个场景完全不冲突，桥都支持。
//

import Foundation

/// 远端文件预览内容（read_file / read_media_file 强类型响应）。
/// 对齐 ccpocket `file_content` 消息的 `kind` 路由：
///   - .text(text, language, totalLines, truncated)：文本 / 代码 / Markdown / HTML
///   - .image(base64, mimeType, sizeBytes)：≤5MB 图片 base64 内联
///   - .audio(mediaUrl, mimeType, sizeBytes)：音频流式
///   - .video(mediaUrl, mimeType, sizeBytes)：视频流式
///   - .failed(error)：File not found / Path not allowed / Image too large 等
enum RemoteFileContent: Sendable, Equatable {
    case text(content: String, language: String?, totalLines: Int?, truncated: Bool?)
    case image(base64: String, mimeType: String?, sizeBytes: Int64?)
    case audio(mediaURL: URL, mimeType: String?, sizeBytes: Int64?)
    case video(mediaURL: URL, mimeType: String?, sizeBytes: Int64?)
    case failed(error: String)

    /// 文件路径（用于错误信息、UI 显示路径名）。
}


/// 包装远端文件 peek 请求,让它可当 fullScreenCover(item:) 的 Identifiable id。
/// 由 AIChatViewModel.handleRemoteFilePeekTap 构造后赋给 vm.pendingRemoteFilePeek,
/// AIChatView 监听它弹 RemoteFilePeekSheet。
///
/// sheet 内部自己在 .task 里调 fetcher()(对齐 ccpocket file_peek_sheet.dart
/// 在 initState 里发 read_file/read_media_file + 自己渲染 loading spinner),
/// 所以 item 只带请求参数 + fetch 闭包,不带结果。
struct RemoteFilePeekItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let filePath: String
    let projectPath: String
    let fetcher: @Sendable () async throws -> RemoteFileContent

    // [T-ios-remotepeek-equatable] Required by .onChange(of:) modifier in
    // RemoteFilePeekPresentationModifier — SwiftUI passes the new value as
    // `Optional<RemoteFilePeekItem>`, and Optional is only Equatable when its
    // wrapped type is. We can't synthesize Equatable because `fetcher` is a
    // @Sendable closure (not Equatable itself); two items are "equal" iff
    // they share the same UUID — which is what sheet identity actually cares
    // about (don't re-render the same peek).
    static func == (lhs: RemoteFilePeekItem, rhs: RemoteFilePeekItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// 单文件读内容操作。对齐 ccpocket file_peek_sheet.dart:296-310
/// `ClientMessage.readFile` / `readMediaFile` + 桥 websocket.ts:5930。
struct RemoteFileContentFetcher: Sendable {
    let client: CCPocketClient
    let projectPath: String
    let filePath: String

    init(client: CCPocketClient, projectPath: String, filePath: String) {
        self.client = client
        self.projectPath = projectPath
        self.filePath = filePath
    }

    /// 根据扩展名选 RPC：音视频走 read_media_file（媒体流式），
    /// 其他走 read_file（文本/小图 base64）。对齐 ccpocket
    /// `mediaFileTypeForPath(filePath)` 判断。
    func fetch(maxLines: Int? = nil) async throws -> RemoteFileContent {
        if Self.isMediaFile(path: filePath) {
            return try await fetchMedia()
        } else {
            return try await fetchText(maxLines: maxLines)
        }
    }

    // MARK: - text / image via read_file

    private func fetchText(maxLines: Int?) async throws -> RemoteFileContent {
        let payload = try await client.readFile(
            projectPath: projectPath,
            filePath: filePath,
            maxLines: maxLines
        )
        let response = try Self.decodeFileContent(payload)
        return Self.parseTextResponse(response)
    }

    /// [String: Any] 原始 dict → 强类型 FileContentResponse。
    /// JSONSerialization 桥接，dict 由 sendAndWaitRPC 返回。
    static func decodeFileContent(_ payload: [String: Any]) throws -> CCPocketProtocol.FileContentResponse {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(CCPocketProtocol.FileContentResponse.self, from: data)
    }

    static func parseTextResponse(_ response: CCPocketProtocol.FileContentResponse) -> RemoteFileContent {
        if let error = response.error, !error.isEmpty {
            return .failed(error: error)
        }
        // kind 路由：image → base64 内联；其余当文本
        if response.kind == "image", let base64 = response.base64, !base64.isEmpty {
            return .image(
                base64: base64,
                mimeType: response.mimeType,
                sizeBytes: response.sizeBytes
            )
        }
        return .text(
            content: response.content ?? "",
            language: response.language,
            totalLines: response.totalLines,
            truncated: response.truncated
        )
    }

    // MARK: - audio / video via read_media_file

    private func fetchMedia() async throws -> RemoteFileContent {
        let payload = try await client.readMediaFile(
            projectPath: projectPath,
            filePath: filePath
        )
        let response = try Self.decodeFileContent(payload)
        return Self.parseMediaResponse(response, httpBaseURL: client.httpBaseURL)
    }

    static func parseMediaResponse(_ response: CCPocketProtocol.FileContentResponse, httpBaseURL: URL?) -> RemoteFileContent {
        if let error = response.error, !error.isEmpty {
            return .failed(error: error)
        }
        let kind = response.kind ?? ""
        guard let relative = response.mediaUrl,
              let absolute = absoluteMediaURL(relative: relative, httpBaseURL: httpBaseURL) else {
            return .failed(error: "Missing mediaUrl in response")
        }
        let mime = response.mimeType
        let size = response.sizeBytes
        switch kind {
        case "audio": return .audio(mediaURL: absolute, mimeType: mime, sizeBytes: size)
        case "video": return .video(mediaURL: absolute, mimeType: mime, sizeBytes: size)
        default: return .failed(error: "Unknown media kind: \(kind)")
        }
    }

    /// 把相对 `/api/media/<id>` 拼成完整 http URL（用 caller 提供的
    /// httpBaseURL，避免 fetcher 自己再算一次）。
    /// 共享 helper — 把桥返回的相对路径（如 `/api/uploads/<token>` /
    /// `/api/media/<id>`）拼成绝对 URL，**保留 baseURL 的 path 段**
    /// （如 /bridge/）— URL(string:relativeTo:) 在 base 有 path 时按
    /// RFC3986 行为是"替换 base.path"，会把 /bridge/ 段丢成裸
    /// /api/...，nginx/Cloudflare 反代路由 miss →
    /// NSURLErrorCannotFindHost。改 URLComponents 显式
    /// basePath + relative 拼接 + host nil 守卫。
    ///
    /// [Claudio 2026-09-06] 抽到 RemoteFileContent 单一文件,避免全局
    /// 函数在 RemoteFileUpload/Download 重复定义导致 Swift 编译
    /// "invalid redeclaration" 错。
    static func composeBridgeAbsoluteURL(relative: String, base: URL) -> URL? {
        guard let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let host = baseComponents.host else { return nil }
        var c = URLComponents()
        c.scheme = baseComponents.scheme
        c.host = host
        c.port = baseComponents.port
        c.path = baseComponents.path + relative
        return c.url
    }

    static func absoluteMediaURL(relative: String, httpBaseURL: URL?) -> URL? {
        guard let httpBaseURL else { return nil }
        return composeBridgeAbsoluteURL(relative: relative, base: httpBaseURL)
    }

    // MARK: - Media type detection

    /// 媒体扩展名表（audio/video）。对齐 ccpocket
    /// `apps/mobile/lib/utils/media_file_types.dart:mediaFileTypesByExtension`。
    /// 复制一份而不引跨包数据，避免依赖。
    static let mediaExtensions: Set<String> = [
        // audio
        "wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "aif", "aiff", "aifc",
        // video
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "mpg", "mpeg",
    ]

    static func isMediaFile(path: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent
        let dotIdx = fileName.lastIndex(of: ".")
        guard let dotIdx, dotIdx < fileName.endIndex else { return false }
        let ext = fileName[fileName.index(after: dotIdx)...].lowercased()
        return mediaExtensions.contains(ext)
    }
}

