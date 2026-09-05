import SwiftUI
import PDFKit
import UIKit
import UniformTypeIdentifiers

// MARK: - FilePreviewPanel (Claudio 2026-09-06)
//
// 远端 agent 工具输出文件的全屏预览面板。
// **不**走 QLPreviewController：pp 要求自定义顶栏 + 右上角 ... 菜单（自适应文件类型）。
//
// 布局：
// ┌──────────────────────────────────────┐
// │  ‹   filename                  ⋯   │  ← 顶栏
// ├──────────────────────────────────────┤
// │   内容（按 FileKind 渲染）            │
// └──────────────────────────────────────┘
//
// 内容渲染（按 FileKind 路由，全部走 Claudio 现有组件或标准框架）：
//   - .image   → Image(uiImage:)，自适应缩放，支持 pinch/double-tap
//   - .code    → MinisTextPreviewView（QLPreviewController 包装，代码预览够用）
//   - .document(MD/文本) → SelectableMarkdownView（复用 OpenMinis 现有 markdown 组件）
//   - .document(PDF)    → PDFKit 渲染（保留 ... 菜单能力，QL 会吞掉 Menu）
//   - .video   → MinisVideoFullscreenPlayer
//   - .audio   → MinisAudioPreviewView
//   - .file    → MinisDocumentPreviewView（QL 兜底，菜单仍可见）
//
// 右上角 ... 菜单：FilePreviewAction 集合，按 FileKind 过滤。
// 见 FilePreviewAction 注释里的"菜单矩阵"。

struct FilePreviewPanel: View {
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var pendingAction: FilePreviewAction?
    @State private var showShare = false
    @State private var showFileExporter = false
    @State private var exportedFileURL: URL?
    @State private var actionToast: String?
    @State private var loadedImage: UIImage?

    private var fileName: String { fileURL.lastPathComponent }

    /// 菜单/渲染统一走 FileKind.fromExtension（panel 不接收 mimeType，URL 扩展名够用）
    private var kind: FileKind {
        FileKind.fromExtension(fileURL.pathExtension.lowercased())
    }

    private var fileSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    var body: some View {
        NavigationStack {
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ChatColors.background.ignoresSafeArea())
                .navigationTitle(fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .accessibilityLabel(Text(AppLocalized("Close")))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        actionsMenu
                    }
                }
                .sheet(isPresented: $showShare) {
                    MinisShareSheet(url: fileURL)
                }
                .sheet(isPresented: $showFileExporter) {
                    if let exportedFileURL {
                        FileExporterSheet(fileURL: exportedFileURL)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let actionToast {
                        ToastBanner(text: actionToast)
                            .padding(.bottom, 32)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: actionToast)
                .onAppear { loadImageIfNeeded() }
        }
    }

    // MARK: - 内容 dispatch

    @ViewBuilder
    private var contentView: some View {
        switch kind {
        case .image:
            imageContent
        case .code:
            // 代码走 QLPreviewController（够用，菜单在 Toolbar 仍可见）
            MinisDocumentPreviewView(fileURL: fileURL)
        case .document:
            documentContent
        case .video:
            MinisVideoFullscreenPlayer(fileURL: fileURL)
        case .audio:
            MinisAudioPreviewView(fileURL: fileURL)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        case .file:
            MinisDocumentPreviewView(fileURL: fileURL)
        }
    }

    /// 图片：直接 SwiftUI Image（pinch/double-tap 通过 MagnificationGesture 自带）
    @ViewBuilder
    private var imageContent: some View {
        if let img = loadedImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 文档：按 mime/扩展名再分（PDF vs MD vs 纯文本）
    @ViewBuilder
    private var documentContent: some View {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "pdf" {
            PDFKitRepresentedView(url: fileURL)
        } else if ext == "md" || ext == "markdown" {
            // 复用现有 markdown 选择视图（带行号 / 复制）
            MinisMarkdownPreviewView(fileURL: fileURL)
        } else {
            MinisDocumentPreviewView(fileURL: fileURL)
        }
    }

    // MARK: - ... 菜单

    @ViewBuilder
    private var actionsMenu: some View {
        let available = FilePreviewAction.available(for: kind, fileName: fileName)
        Menu {
            ForEach(available) { action in
                Button {
                    pendingAction = action
                    Task { await performAction(action) }
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .medium))
        }
        .accessibilityLabel(Text(AppLocalized("More actions")))
    }

    // MARK: - 动作分发

    private func performAction(_ action: FilePreviewAction) async {
        let result = await FilePreviewActionExecutor.execute(
            action,
            fileURL: fileURL,
            fileName: fileName,
            fileSize: fileSize,
            kind: kind
        )
        switch result {
        case .toast(let text):
            actionToast = text
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                if actionToast == text { actionToast = nil }
            }
        case .share:
            showShare = true
        case .exportFile(let exported):
            exportedFileURL = exported
            showFileExporter = true
        case .noop:
            break
        }
    }

    // MARK: - 图片懒加载（避免 NavigationStack 出现瞬间全屏 Image 触发 layout pass）

    private func loadImageIfNeeded() {
        guard kind == .image, loadedImage == nil else { return }
        let path = fileURL.path
        Task {
            // [swiftui-pro 4.49] 不用 DispatchQueue.global：Task.detached 跳到后台
            // actor 是正当用法（UI 解码大图不能在 main thread）。
            let img: UIImage? = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)
            }.value
            if let img { loadedImage = img }
        }
    }
}

// MARK: - PDFKit 包装（保留 ... 菜单能力，QLPreviewController 会吞掉 toolbar）

private struct PDFKitRepresentedView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // 文件不会变，无需 reload
    }
}

// MARK: - FileExporterSheet（"在 Files 中查看" / "导出 PDF" / "导出 Markdown" 共用）

private struct FileExporterSheet: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DocumentExporterView(fileURL: fileURL, onFinish: { dismiss() })
            .ignoresSafeArea()
    }
}

/// UIKit UIDocumentPickerViewController(forExporting:) 的 SwiftUI 包装。
/// 在 Files / iCloud Drive / 其他 app 位置创建一份副本。
private struct DocumentExporterView: UIViewControllerRepresentable {
    let fileURL: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL])
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}

// MARK: - ToastBanner（"已复制"/"已导出"轻量反馈）

private struct ToastBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.black.opacity(0.78))
            )
    }
}
