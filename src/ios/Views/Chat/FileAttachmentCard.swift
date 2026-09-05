import SwiftUI

// MARK: - FileAttachmentCard (Claudio 2026-09-05)
//
// 1:1 复刻 Claude App 文件卡片：
// - 圆角 16pt + 1pt 浅灰边框 + 白色背景
// - 左侧 96pt 色块图标方块（按文件类型 5 种底色 + SF Symbol）
// - 右侧双行：粗体文件名（17pt）+ 灰色副标题 "Type · EXT · size"（13pt）
// - 整张卡片可点：未下载 → 静默下载；已下载 → 弹 QuickLook 全屏预览
// - 下载中：图标方块叠圆形进度环
// - 失败：图标方块变红叉 + 副标题 "下载失败 · 点击重试"
//
// **仅远端 agent 用**：本地 agent 永不写 AssistantBlock.outputFileRemotePath
// （ChatStore.applyPersistedToolResult 的 if-of 分支只对 tr.outputFile 非空时进，
// 而 tr.outputFile 永远只由 RemoteAgentProvider 写入）。本地 agent 走
// MinisFileChipView / AsyncImageTile 现有路径，零侵入。

struct FileAttachmentCard: View {
    let fileName: String
    let mimeType: String?
    let sizeBytes: Int64
    let downloadState: FileDownloadState
    let onTap: () -> Void

    private var kind: FileKind { FileKind.from(mimeType: mimeType, fileName: fileName) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                FileIconBlock(kind: kind, downloadState: downloadState)
                    .frame(width: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(fileName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitleText)
                        .font(.system(size: 13))
                        .foregroundStyle(
                            downloadState.isFailed ? Color.red.opacity(0.85) : ChatColors.secondaryText
                        )
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 96)
            .background(ChatColors.background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(downloadState.isFailed
                            ? Color.red.opacity(0.4)
                            : ChatColors.toolBorder,
                            lineWidth: 1)
            )
            .opacity(downloadState.isFailed ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var subtitleText: String {
        let ext = (fileName as NSString).pathExtension.uppercased()
        switch downloadState {
        case .idle:
            var parts: [String] = [kind.typeLabel]
            if !ext.isEmpty { parts.append(ext) }
            if sizeBytes > 0 { parts.append(formatSize(sizeBytes)) }
            parts.append("在用户机器上")
            return parts.joined(separator: " · ")
        case .preparing:
            return "准备下载..."
        case .downloading(let p):
            return "下载中... \(Int(p * 100))%"
        case .ready:
            return "已下载到本机"
        case .failed(_, let msg):
            return "下载失败 · 点击重试"
                .appending(msg.isEmpty ? "" : "  (\(msg))")
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - FileIconBlock (色块 + 状态图标)

private struct FileIconBlock: View {
    let kind: FileKind
    let downloadState: FileDownloadState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(kind.backgroundColor)
            content
                .padding(12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch downloadState {
        case .downloading(let p):
            ProgressView(value: p)
                .progressViewStyle(.circular)
                .tint(kind.iconColor)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(kind.iconColor.opacity(0.7))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.red.opacity(0.75))
        case .idle, .preparing:
            Image(systemName: kind.symbolName)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(kind.iconColor)
        }
    }
}

// MARK: - FileDownloadState helpers

extension FileDownloadState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - FileKind (5 种类型 + 兜底)

/// 5 种 Claude 风格文件类型分组 + 未知类型走 .file 兜底。
/// MIME 推断：优先用 bridge 推过来的 mimeType，fallback 用扩展名表。
enum FileKind {
    case document, code, image, video, audio, file

    var symbolName: String {
        switch self {
        case .document: return "doc.text"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .image:    return "photo"
        case .video:    return "play.rectangle"
        case .audio:    return "music.note"
        case .file:     return "doc"
        }
    }

    /// "Document" / "Code" / "Image" / "Video" / "Audio" / "File" — 跟 Claude 副标题一致
    var typeLabel: String {
        switch self {
        case .document: return "Document"
        case .code:     return "Code"
        case .image:    return "Image"
        case .video:    return "Video"
        case .audio:    return "Audio"
        case .file:     return "File"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .document: return ChatColors.fileCardDocBg
        case .code:     return ChatColors.fileCardCodeBg
        case .image:    return ChatColors.fileCardImageBg
        case .video:    return ChatColors.fileCardVideoBg
        case .audio:    return ChatColors.fileCardAudioBg
        case .file:     return Color(UIColor.systemGray6)
        }
    }

    var iconColor: Color {
        switch self {
        case .document: return ChatColors.fileCardDocFg
        case .code:     return ChatColors.fileCardCodeFg
        case .image:    return ChatColors.fileCardImageFg
        case .video:    return ChatColors.fileCardVideoFg
        case .audio:    return ChatColors.fileCardAudioFg
        case .file:     return ChatColors.primaryText
        }
    }

    /// mime 优先；fallback 用扩展名表。ccpocket bridge 给的 mimeType 可能缺，
    /// RemoteAgentProvider 也可能传 nil（文本解析路径不推断 mime）。
    static func from(mimeType: String?, fileName: String) -> FileKind {
        if let m = mimeType?.lowercased(), !m.isEmpty {
            // text/* — 细分代码 vs 纯文本/标记
            if m.hasPrefix("text/") {
                let codeHints = ["python", "swift", "javascript", "typescript",
                                 "rust", "java", "ruby", "go", "kotlin", "c++",
                                 "perl", "php", "scala", "html", "css", "shellscript"]
                if codeHints.contains(where: m.contains) { return .code }
                return .document   // text/plain, text/markdown, text/xml ...
            }
            if m.hasPrefix("image/") { return .image }
            if m.hasPrefix("video/") { return .video }
            if m.hasPrefix("audio/") { return .audio }
            if m == "application/pdf"
                || m.contains("officedocument")
                || m.contains("msword")
                || m.contains("opendocument") {
                return .document
            }
            if m == "application/json"
                || m == "application/xml"
                || m == "application/yaml" {
                return .code
            }
            // application/octet-stream 或其他未知 → fallback 走扩展名
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return fromExtension(ext)
    }

    /// 扩展名 → FileKind。跟 minisFileIcon 现有映射（MinisMediaViews.swift:331）逻辑一致，
    /// 但用我们自己的分类（代码 vs 文本），不共享表（避免耦合）。
    static func fromExtension(_ ext: String) -> FileKind {
        switch ext {
        // Code
        case "py", "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs",
             "html", "css", "scss", "sass", "less",
             "json", "xml", "yaml", "yml", "toml", "plist",
             "sh", "bash", "zsh", "fish",
             "rs", "go", "java", "kt", "kts", "c", "h", "cpp", "hpp", "cc",
             "rb", "php", "pl", "scala", "clj", "ex", "exs", "lua", "r":
            return .code
        // Document
        case "md", "markdown", "txt", "rst", "adoc",
             "pdf", "doc", "docx", "rtf", "odt", "pages",
             "csv", "tsv", "xls", "xlsx", "numbers",
             "ppt", "pptx", "key", "epub":
            return .document
        // Image
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif",
             "tiff", "tif", "svg", "ico", "raw":
            return .image
        // Video
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "3gp":
            return .video
        // Audio
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "wma", "aiff":
            return .audio
        default:
            return .file
        }
    }
}
