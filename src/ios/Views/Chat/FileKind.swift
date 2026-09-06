import SwiftUI
import UIKit

// MARK: - FileKind (Claudio 2026-09-06, 拆分自原 FileAttachmentCard.swift)
//
// 5 种 Claude 风格文件类型分组 + 未知类型走 .file 兜底。
// 配色 1:1 复刻 Claude App 文件卡片（light/dark 动态），颜色定义在文件底部
// FileKindColors — 私有，不对外暴露，使用方按 .backgroundColor / .iconColor 拿。
//
// 历史：2026-09-05 引入时与 FileAttachmentCard 同文件，2026-09-06 卡片删除后
// 拆为独立文件，保留给 FilePreviewPanel / FilePreviewActions / future
// file-kind-aware UI 用。

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
        case .document: return FileKindColors.docBg
        case .code:     return FileKindColors.codeBg
        case .image:    return FileKindColors.imageBg
        case .video:    return FileKindColors.videoBg
        case .audio:    return FileKindColors.audioBg
        case .file:     return Color(UIColor.systemGray6)
        }
    }

    var iconColor: Color {
        switch self {
        case .document: return FileKindColors.docFg
        case .code:     return FileKindColors.codeFg
        case .image:    return FileKindColors.imageFg
        case .video:    return FileKindColors.videoFg
        case .audio:    return FileKindColors.audioFg
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

// MARK: - FileKindColors (Claudio 2026-09-06, 拆分自 ChatColors.fileCard* token)
//
// 1:1 复刻 Claude App 文件卡片配色。light/dark 动态 — dark 模式下调亮底色让
// 图标仍清晰。颜色值从原 ChatColors.fileCard* (AIChatView.swift) 1:1 复制 —
// 任何调整都会影响 FilePreviewPanel / FilePreviewActions 的现有渲染。
//
// 2026-09-06 拆出理由：原 token 挂在 ChatColors 里、被注释"FileAttachmentCard
// 是唯一使用方"框死；卡片删除后 token 跟着 FileKind 一起迁到这里，私有不
// 再污染 ChatColors 公共 token 列表。

private enum FileKindColors {
    static let docBg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.12, green: 0.20, blue: 0.32, alpha: 1)   // dark 深蓝
        : UIColor(red: 0.90, green: 0.94, blue: 0.98, alpha: 1)  // light #E5F0FA
    })
    static let docFg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.55, green: 0.75, blue: 1.00, alpha: 1)
        : UIColor(red: 0.12, green: 0.36, blue: 0.72, alpha: 1)  // light #1E5BB8
    })

    static let codeBg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.28, green: 0.24, blue: 0.10, alpha: 1)   // dark 深黄
        : UIColor(red: 1.00, green: 0.96, blue: 0.84, alpha: 1)  // light #FFF4D6
    })
    static let codeFg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.00, green: 0.85, blue: 0.50, alpha: 1)
        : UIColor(red: 0.60, green: 0.40, blue: 0.00, alpha: 1)  // light #9A6700
    })

    static let imageBg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.22, green: 0.18, blue: 0.32, alpha: 1)   // dark 深紫
        : UIColor(red: 0.93, green: 0.91, blue: 0.96, alpha: 1)  // light #EDE7F6
    })
    static let imageFg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.75, green: 0.65, blue: 0.95, alpha: 1)
        : UIColor(red: 0.37, green: 0.21, blue: 0.69, alpha: 1)  // light #5E35B1
    })

    static let videoBg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.10, green: 0.22, blue: 0.14, alpha: 1)   // dark 深绿
        : UIColor(red: 0.91, green: 0.96, blue: 0.91, alpha: 1)  // light #E8F5E9
    })
    static let videoFg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.50, green: 0.85, blue: 0.55, alpha: 1)
        : UIColor(red: 0.18, green: 0.49, blue: 0.20, alpha: 1)  // light #2E7D32
    })

    static let audioBg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.32, green: 0.20, blue: 0.08, alpha: 1)   // dark 深橙
        : UIColor(red: 1.00, green: 0.88, blue: 0.70, alpha: 1)  // light #FFE0B2
    })
    static let audioFg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.00, green: 0.75, blue: 0.45, alpha: 1)
        : UIColor(red: 0.90, green: 0.32, blue: 0.00, alpha: 1)  // light #E65100
    })
}
