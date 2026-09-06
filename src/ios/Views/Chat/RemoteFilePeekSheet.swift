//
//  RemoteFilePeekSheet.swift
//  MinisApp
//
//  远端 agent 正文文件路径点击 → 按需读内容预览面板。
//
//  UI 走 Claude app 式极简预览（pp 2026-09-06 拍板：不要 ccpocket 的
//  顶栏按钮群 + 元信息行，要 Claude app 那种干净的感觉）：
//  - 顶栏：文件名 + 关闭，仅此而已
//  - 内容区：按类型渲染（代码高亮 / markdown / html / 图片 / 音视频流式）
//  - 底部：极简动作条，按文件类型给「复制路径 / 分享」
//  - 加载/错误态在面板内部（.task 调 fetcher）
//
//  数据层仍然对齐 ccpocket file_peek 协议（read_file / read_media_file，
//  与 RemoteFileContentFetcher 对接），只是 UI 皮换成 Claude 风格。
//

import SwiftUI
import WebKit

// MARK: - 轻量代码高亮器（无第三方依赖）

/// 通用轻量语法高亮：注释 / 字符串 / 数字 / 关键字四类 token。
/// 桥端 languageMap 覆盖 30+ 语言，这里做语言无关的通用高亮。
enum RemoteCodeHighlighter {
    static let lineCommentMarkers = ["//", "#", "--"]
    static let blockCommentPairs: [(String, String)] = [("/*", "*/"), ("<!--", "-->")]

    static let keywords: Set<String> = [
        // Swift
        "let", "var", "func", "class", "struct", "enum", "extension", "protocol",
        "import", "guard", "if", "else", "switch", "case", "default", "for", "while",
        "repeat", "break", "continue", "return", "throw", "throws", "try", "catch",
        "do", "in", "where", "as", "is", "nil", "true", "false", "self", "super",
        "static", "private", "public", "internal", "fileprivate", "open", "init",
        "deinit", "mutating", "nonmutating", "override", "final", "lazy", "weak",
        "unowned", "required", "convenience", "some", "any", "async", "await",
        "actor", "Task", "nonisolated", "escaping", "inout", "associatedtype",
        "typealias", "get", "set", "willSet", "didSet", "indirect", "operator",
        "precedencegroup",
        // Python
        "def", "lambda", "pass", "elif", "with", "global", "nonlocal", "assert",
        "yield", "raise", "except", "finally", "from", "del", "not", "and", "or",
        "None",
        // JS/TS
        "const", "function", "new", "typeof", "instanceof", "undefined", "null",
        "this", "export", "extends", "implements", "interface", "namespace",
        "declare", "readonly",
    ]

    /// 高亮整段代码：base 染色后按 注释 → 字符串 → 数字 → 关键字 覆盖。
    static func highlight(_ code: String, fontSize: Double = 13) -> NSAttributedString {
        let baseFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: baseFont,
            .foregroundColor: UIColor.label,
        ])
        let ns = code as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        let commentColor = UIColor.systemGreen
        let stringColor = UIColor.systemRed
        let numberColor = UIColor.systemOrange
        let keywordColor = UIColor.systemBlue

        // 1) 块注释
        for (open, close) in blockCommentPairs {
            let pattern = NSRegularExpression.escapedPattern(for: open)
                + "[\\s\\S]*?" + NSRegularExpression.escapedPattern(for: close)
            if let re = try? NSRegularExpression(pattern: pattern) {
                for m in re.matches(in: code, range: fullRange) {
                    result.addAttribute(.foregroundColor, value: commentColor, range: m.range)
                }
            }
        }

        // 2) 行注释
        let lineCommentPattern = "(^|[\\s])(?:(?:"
            + lineCommentMarkers.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            + ")[^\\n]*)"
        if let re = try? NSRegularExpression(pattern: lineCommentPattern, options: [.anchorsMatchLines]) {
            for m in re.matches(in: code, range: fullRange) {
                result.addAttribute(.foregroundColor, value: commentColor, range: m.range)
            }
        }

        // 3) 字符串
        for quote in ["\"", "'"] {
            let pattern = NSRegularExpression.escapedPattern(for: quote)
                + "[^" + NSRegularExpression.escapedPattern(for: quote) + "\\n]*"
                + NSRegularExpression.escapedPattern(for: quote)
            if let re = try? NSRegularExpression(pattern: pattern) {
                for m in re.matches(in: code, range: fullRange) {
                    result.addAttribute(.foregroundColor, value: stringColor, range: m.range)
                }
            }
        }

        // 4) 数字
        if let re = try? NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b") {
            for m in re.matches(in: code, range: fullRange) {
                result.addAttribute(.foregroundColor, value: numberColor, range: m.range)
            }
        }

        // 5) 关键字（长词优先防前缀误匹配）
        let kwPattern = "\\b(" + keywords.sorted(by: { $0.count > $1.count }).map(NSRegularExpression.escapedPattern).joined(separator: "|") + ")\\b"
        if let re = try? NSRegularExpression(pattern: kwPattern) {
            for m in re.matches(in: code, range: fullRange) {
                result.addAttribute(.foregroundColor, value: keywordColor, range: m.range)
            }
        }

        return result
    }
}

// MARK: - 预览面板（Claude app 式极简 UI）

/// 远端文件按需预览面板。item 由 AIChatViewModel.handleRemoteFilePeekTap
/// 构造，面板内部 .task 自己 fetch（数据层对齐 ccpocket file_peek）。
struct RemoteFilePeekSheet: View {
    let item: RemoteFilePeekItem

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var showFullscreenImage = false

    enum Phase {
        case loading
        case failed(String)
        case loaded(RemoteFileContent)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            contentView
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .task { await load() }
    }

    private func load() async {
        if case .loaded = phase { return }
        phase = .loading
        do {
            phase = .loaded(try await item.fetcher())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 顶栏：文件名 + 关闭，仅此而已

    private var topBar: some View {
        HStack {
            Text(fileName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .safeAreaPadding(.top)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentView: some View {
        switch phase {
        case .loading:
            Spacer()
            ProgressView()
            Spacer()
        case .failed(let message):
            failedContent(message)
        case .loaded(let content):
            VStack(spacing: 0) {
                loadedContent(content)
                actionBar(for: content)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ content: RemoteFileContent) -> some View {
        switch content {
        case .text(let text, _, _, _):
            if isMarkdownFile {
                SelectableMarkdownView(markdown: text)
                    .padding(.horizontal, 4)
            } else if isHTMLFile {
                HTMLContentView(html: text)
            } else {
                CodeContentView(code: text)
            }
        case .image(let base64, _, _):
            if let data = Data(base64Encoded: base64), let uiImage = UIImage(data: data) {
                ZStack {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.9))
                        .onTapGesture { showFullscreenImage = true }
                    // 全屏查看 overlay（不嵌套 fullScreenCover，避免
                    // 双 presenter 冲突）
                    if showFullscreenImage {
                        Color.black.ignoresSafeArea()
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .ignoresSafeArea()
                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    showFullscreenImage = false
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(10)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            } else {
                failedContent("Image decode failed")
            }
        case .audio(let url, _, _):
            MinisAudioPreviewView(fileURL: url)
        case .video(let url, _, _):
            MinisVideoFullscreenPlayer(fileURL: url)
        case .failed(let error):
            failedContent(error)
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部极简动作条（按文件类型）

    @ViewBuilder
    private func actionBar(for content: RemoteFileContent) -> some View {
        HStack(spacing: 16) {
            Button {
                UIPasteboard.general.string = item.filePath
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground).opacity(0.5))
    }

    // MARK: - Helpers

    private var fileName: String {
        (item.filePath as NSString).lastPathComponent
    }

    private var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    private var isMarkdownFile: Bool {
        ["md", "markdown"].contains(fileExtension)
    }

    private var isHTMLFile: Bool {
        ["html", "htm"].contains(fileExtension)
    }
}

// MARK: - CodeContentView（高亮代码 UITextView）

private struct CodeContentView: UIViewRepresentable {
    let code: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.attributedText = RemoteCodeHighlighter.highlight(code)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}
}

// MARK: - HTMLContentView（WKWebView 渲染远端 HTML 内容）

private struct HTMLContentView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
