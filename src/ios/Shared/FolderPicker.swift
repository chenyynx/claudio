import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SwiftUI UIViewControllerRepresentable 包装 UIDocumentPickerViewController，
/// **in-place 模式**（asCopy:false）专用于选择文件夹。
///
/// 【为什么单独拆出来】
/// `ImportDocumentPicker` 用 `asCopy:true` import 模式处理文档类 UTI
///（json / pdf / image / data）— 这是 [Fix 09-05-2] 用来绕开 iOS 26.2 上
/// .fileImporter 回调丢失的方案。但 folder 是 directory UTI，asCopy 模式下
/// 没有"复制"语义：iOS 18+ 在 picker 内部对 .folder + asCopy:true 抛
/// NSException，Swift catch 不住 → SIGABRT 闪退。
///
/// 选文件夹需要的是 in-place picker：返回的 URL 是源文件夹本身（带 security
/// scope），可以 `startAccessingSecurityScopedResource()` + `bookmarkData()`
/// 持久化，下次启动解析后保持访问权限 — 这正是 `MountedFoldersManager.add`
/// 期望的 URL 形态。Import 模式返回沙箱副本，没有 scope，bookmark 后续无法
/// 激活。
///
/// 【与 ImportDocumentPicker 的边界】
/// | 用途 | UTI 类型 | 组件 |
/// |------|----------|------|
/// | 选文档（json/pdf/图片/数据） | document | `ImportDocumentPicker` (asCopy:true) |
/// | 选文件夹 | directory (.folder) | **`FolderPicker`** (asCopy:false) |
///
/// 【生命周期】
/// - onAppear：picker 自动 present
/// - didPick: 调 onPick(URL)
///
/// [T-ios-folder-picker-asCopy-stable-callback]
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy:false → in-place 模式：返回源文件夹 URL，带 security scope，
        // 调用方通过 startAccessing/stopAccessing + bookmarkData 持久化。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // no-op
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker

        init(_ parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // in-place 模式：urls 是源文件夹 URL，带 security scope，
            // 调用方需在 startAccessingSecurityScopedResource 的窗口内
            // 完成 bookmarkData() 等持久化操作。
            importLog.info("[FolderPicker] didPick \(urls.count) folder(s): \(urls.map { $0.lastPathComponent })")
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
    }
}

private let importLog = AppLogger(category: "FolderPicker")
