import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SwiftUI UIViewControllerRepresentable 包装 UIDocumentPickerViewController，
/// 用 **asCopy:true import 模式** 替代 .fileImporter。
///
/// 【为什么不用 .fileImporter】
/// SwiftUI .fileImporter / in-place(security-scoped) picker 在 iOS 26.2 +
/// 重度呈现上下文下点 "Open" 后跨进程回调丢失：picker 不 dismiss、completion
/// 永不触发，无法诊断也无法修复。import 模式系统把文件复制进沙箱、返回普通
/// URL（无 scope 握手），直接绕过断掉的链路。asCopy 由系统保证，URL 不需要
/// startAccessingSecurityScopedResource。
///
/// 【生命周期】
/// - onAppear：picker 自动 present（无需外部 sheet 嵌套，但 callers 包了
///   .sheet 也没问题）
/// - didPick: 调 onPick([URL])
/// - wasCancelled: 调 onCancel()
/// - 两者都不会静默吞掉回调——iOS 26.x 上稳定。
///
/// 【使用方】
/// 5 个 .fileImporter 调用点全部替换（AIChatView 附件、AddProviderView
/// 导入 JSON、ProviderInstancesView 导入 JSON、BackupDestinationPicker
/// 选文件夹、BackupRestoreView 选备份文件）。
///
/// [T-ios-documentpicker-asCopy-stable-callback]
struct ImportDocumentPicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    var allowsMultipleSelection: Bool = false
    let onPick: ([URL]) -> Void
    var onCancel: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // [T-ios-folder-picker-asCopy-stable-callback] `asCopy:true` 仅对
        // document UTI 有意义；对**纯 directory UTI 数组**（全 .folder /
        // .directory）iOS 18+ 在 picker 内部抛 NSException → SIGABRT 闪退。
        // 选文件夹请用 Shared/FolderPicker.swift。
        //
        // 混选 UTI 数组（document + directory，例如 AIChatView 附件选择器）
        // iOS 容忍不闪退，但 folder 会被当成普通 document 处理（addFileAttachment
        // 走 moveItem/copyItem 路径，把文件夹当文件），不是真挂载 — 这是另一
        // 个独立问题，不在本组件边界内。
        let isPureDirectory = !allowedContentTypes.isEmpty
            && allowedContentTypes.allSatisfy { $0.conforms(to: .folder) || $0.conforms(to: .directory) }
        assert(
            !isPureDirectory,
            "ImportDocumentPicker 不支持纯 directory UTI 数组（asCopy:true + pure directory 闪退）；选文件夹请改用 Shared/FolderPicker.swift"
        )
        // asCopy:true → import 模式：系统复制到沙箱，返回普通 URL，无 scope 握手
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
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
        let parent: ImportDocumentPicker

        init(_ parent: ImportDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // asCopy:true：urls 已是沙箱内副本，importLog 直接记录
            importLog.info("[ImportDocumentPicker] didPick \(urls.count) file(s): \(urls.map { $0.lastPathComponent })")
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            importLog.info("[ImportDocumentPicker] wasCancelled")
            parent.onCancel?()
        }
    }
}

private let importLog = AppLogger(category: "ImportDocumentPicker")
