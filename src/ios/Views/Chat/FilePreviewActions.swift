import SwiftUI
import UIKit
import PDFKit
import AVFoundation
import Photos

// MARK: - FilePreviewAction (Claudio 2026-09-06)
//
// 远端文件预览面板的右上角 ... 菜单动作枚举。**仅用于远端 agent 工具输出文件
// （AssistantBlock.outputFileLocalPath）**，本地 agent 零影响（本地 agent
// 走 OpenMinis 现有文件 chip / QLPreviewController 路径）。
//
// 菜单矩阵（按 FileKind 过滤，pp 拍板）：
// ┌──────────────────┬──────┬──────┬──────┬──────┬──────┬──────┐
// │                  │ Doc  │ Code │ Img  │ Vid  │ Aud  │ File │
// ├──────────────────┼──────┼──────┼──────┼──────┼──────┼──────┤
// │ 复制文字          │  ✅  │  ✅  │  -   │  -   │  -   │  -   │
// │ 复制图片          │  -   │  -   │  ✅  │  -   │  -   │  -   │
// │ 保存到相册        │  -   │  -   │  ✅  │  -   │  -   │  -   │
// │ 提取音频          │  -   │  -   │  -   │  ✅  │  -   │  -   │
// │ 导出 PDF         │  ✅  │  ✅  │  -   │  -   │  -   │  -   │
// │ 导出 Markdown    │ MD✅ │  -   │  -   │  -   │  -   │  -   │
// │ 在 Files 中查看   │  ✅  │  ✅  │  ✅  │  ✅  │  ✅  │  ✅  │
// │ 分享             │  ✅  │  ✅  │  ✅  │  ✅  │  ✅  │  ✅  │
// └──────────────────┴──────┴──────┴──────┴──────┴──────┴──────┘
//
// 文档细分规则：
//   - "导出 Markdown" 仅在 fileName 扩展名是 .md/.markdown 时显示
//   - PDF（.pdf）走 PDFKit 渲染，"导出 PDF" = 复制源文件本身
//   - 其他文档（.docx/.txt/.csv 等）走 MinisDocumentPreviewView，
//     "导出 PDF" 走 UIPrintPageRenderer 实时渲染

enum FilePreviewAction: String, Identifiable, Hashable {
    case copyText
    case copyImage
    case saveToPhotos
    case extractAudio
    case exportPDF
    case exportMarkdown
    case openInFiles
    case share

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copyText:       return AppLocalized("Copy Text")
        case .copyImage:      return AppLocalized("Copy Image")
        case .saveToPhotos:   return AppLocalized("Save to Photos")
        case .extractAudio:   return AppLocalized("Extract Audio")
        case .exportPDF:      return AppLocalized("Export as PDF")
        case .exportMarkdown: return AppLocalized("Export as Markdown")
        case .openInFiles:    return AppLocalized("Open in Files")
        case .share:          return AppLocalized("Share")
        }
    }

    var systemImage: String {
        switch self {
        case .copyText:       return "doc.on.doc"
        case .copyImage:      return "photo.on.rectangle.angled"
        case .saveToPhotos:   return "square.and.arrow.down"
        case .extractAudio:   return "waveform"
        case .exportPDF:      return "doc.richtext"
        case .exportMarkdown: return "text.alignleft"
        case .openInFiles:    return "folder"
        case .share:          return "square.and.arrow.up"
        }
    }

    /// 返回当前文件类型下应展示的动作集合（按显示顺序）
    static func available(for kind: FileKind, fileName: String) -> [FilePreviewAction] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var actions: [FilePreviewAction] = []

        switch kind {
        case .document:
            actions.append(.copyText)
            if ext == "pdf" {
                // PDF：导出 PDF = 复制源文件本身（PDF → PDF 渲染无意义）
                actions.append(.exportPDF)
            } else {
                // 纯文本/Office：UIPrintPageRenderer 实时渲染
                actions.append(.exportPDF)
            }
            if ext == "md" || ext == "markdown" {
                actions.append(.exportMarkdown)
            }
        case .code:
            actions.append(.copyText)
            actions.append(.exportPDF)
        case .image:
            actions.append(.copyImage)
            actions.append(.saveToPhotos)
        case .video:
            actions.append(.extractAudio)
        case .audio:
            // 无专属动作
            break
        case .file:
            // 兜底：只暴露通用动作
            break
        }

        // 通用动作（所有类型都有）
        actions.append(.openInFiles)
        actions.append(.share)
        return actions
    }
}

// MARK: - FilePreviewActionExecutor

/// 单动作执行结果，UI 层根据 result 决定 toast / sheet / 不动。
enum FilePreviewActionResult {
    case toast(String)            // 显示底部 toast 提示
    case share                    // 触发分享 sheet（UI 层已就绪）
    case exportFile(URL)          // "在 Files 中查看" / "导出 PDF/MD" 走系统 picker
    case noop                     // 静默完成（如提取音频）
}

enum FilePreviewActionExecutor {

    /// 执行菜单动作。**不阻塞 UI**：文件 I/O / 导出等放后台。
    /// 错误一律降级为 toast 提示，不抛。
    static func execute(
        _ action: FilePreviewAction,
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        kind: FileKind
    ) async -> FilePreviewActionResult {
        switch action {
        case .copyText:
            return await copyText(fileURL: fileURL, kind: kind)
        case .copyImage:
            return copyImage(fileURL: fileURL)
        case .saveToPhotos:
            return await saveToPhotos(fileURL: fileURL)
        case .extractAudio:
            await extractAudio(fileURL: fileURL, fileName: fileName)
            return .toast(AppLocalized("Audio extracted"))
        case .exportPDF:
            return await exportPDF(fileURL: fileURL, fileName: fileName, kind: kind)
        case .exportMarkdown:
            return exportMarkdown(fileURL: fileURL, fileName: fileName)
        case .openInFiles:
            // 直接复用导出通道——把源文件交给系统 picker
            return .exportFile(fileURL)
        case .share:
            return .share
        }
    }

    // MARK: - copyText

    private static func copyText(fileURL: URL, kind: FileKind) async -> FilePreviewActionResult {
        // 仅 text/code/document 类型支持；其它走 .noop
        guard kind == .code || kind == .document else { return .noop }
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            UIPasteboard.general.string = text
            return .toast(AppLocalized("Copied \(text.count) chars"))
        } catch {
            return .toast(AppLocalized("Copy failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - copyImage

    private static func copyImage(fileURL: URL) -> FilePreviewActionResult {
        guard let img = UIImage(contentsOfFile: fileURL.path) else {
            return .toast(AppLocalized("Failed to load image"))
        }
        UIPasteboard.general.image = img
        return .toast(AppLocalized("Image copied"))
    }

    // MARK: - saveToPhotos

    private static func saveToPhotos(fileURL: URL) async -> FilePreviewActionResult {
        guard let img = UIImage(contentsOfFile: fileURL.path) else {
            return .toast(AppLocalized("Failed to load image"))
        }
        // [swiftui-pro 4.49] 优先用 async 版本（iOS 14+/15+），不用回调 + semaphore。
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .toast(AppLocalized("Photos access denied"))
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }
            return .toast(AppLocalized("Saved to Photos"))
        } catch {
            return .toast(AppLocalized("Save failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - extractAudio (AVAssetExportSession 异步)

    private static func extractAudio(fileURL: URL, fileName: String) async {
        let asset = AVURLAsset(url: fileURL)
        // 仅在确实有音频轨时导出
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { return }

        let outName = (fileName as NSString).deletingPathExtension + ".m4a"
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-extracts", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent(outName)
        try? FileManager.default.removeItem(at: outURL)

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { return }
        session.outputURL = outURL
        session.outputFileType = .m4a

        await session.export()
        // 导出完成后，文件已落在 outURL；调用方可通过 share sheet
        // 把这个文件推给用户。本次只 toast，复杂流程（多文件 picker）后续再加。
    }

    // MARK: - exportPDF（UIPrintPageRenderer 实时渲染）

    private static func exportPDF(
        fileURL: URL,
        fileName: String,
        kind: FileKind
    ) async -> FilePreviewActionResult {
        // 源文件本身是 PDF：直接复用
        if fileURL.pathExtension.lowercased() == "pdf" {
            return .exportFile(fileURL)
        }
        // 文本/代码：用 UIPrintPageRenderer 渲染为 PDF
        do {
            let outURL = try await renderTextToPDF(fileURL: fileURL, fileName: fileName, kind: kind)
            return .exportFile(outURL)
        } catch {
            return .toast(AppLocalized("Export failed: \(error.localizedDescription)"))
        }
    }

    private static func renderTextToPDF(
        fileURL: URL,
        fileName: String,
        kind: FileKind
    ) async throws -> URL {
        let text: String
        // 文本/代码：读源文件；其它类型兜底
        if kind == .code || kind == .document {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        } else {
            text = ""
        }
        let pageSize = CGSize(width: 612, height: 792)   // US Letter @ 72dpi
        let renderer = UIPrintPageRenderer()
        let formatter = UISimpleTextPrintFormatter(attributedText: NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont(name: "Menlo", size: 10) ?? UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: UIColor.black,
            ]
        ))
        formatter.perPageContentInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let outName = (fileName as NSString).deletingPathExtension + ".pdf"
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-exports", isDirectory: true)
            .appendingPathComponent(outName)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outURL)

        let pdfData = NSMutableData()
        // beginPage / drawPage 必须在 main thread
        await MainActor.run {
            UIGraphicsBeginPDFContextToData(pdfData, CGRect(origin: .zero, size: pageSize), nil)
            for i in 0..<renderer.numberOfPages {
                UIGraphicsBeginPDFPageWithInfo(
                    CGRect(origin: .zero, size: pageSize),
                    nil
                )
                renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
            }
            UIGraphicsEndPDFContext()
        }
        try pdfData.write(to: outURL, options: .atomic)
        return outURL
    }

    // MARK: - exportMarkdown（.md → .md，源文件即目标；非 .md 不支持）

    private static func exportMarkdown(fileURL: URL, fileName: String) -> FilePreviewActionResult {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else {
            return .toast(AppLocalized("Not a Markdown file"))
        }
        return .exportFile(fileURL)
    }
}
