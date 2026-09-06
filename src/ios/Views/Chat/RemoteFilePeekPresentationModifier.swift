//
//  RemoteFilePeekPresentationModifier.swift
//  MinisApp
//
//  远端 agent 正文文件路径点击 → RemoteFilePeekSheet 全屏面板的展示 modifier。
//
//  抽离动机：AIChatView body 已 600+ 行，SwiftUI 类型检查器
//  (AIChatView.swift:564 type-check timeout) 在新加 3 个 modifier
//  (onReceive + onChange + fullScreenCover) 后跑不动——这是 OpenMinis
//  v1.13 合并时已踩过的坑（commit 898a8e8 拆闭包解决）。同样的模式：
//  把远端文件 peek 的 state + 3 个 modifier 抽进独立 ViewModifier，
//  body 只剩 `.modifier(RemoteFilePeekPresentationModifier(vm: vm))`
//  一行——Solver 看一眼就知道返回 some View。
//
//  对齐 ccpocket file_peek：触发链路、sheet 内容、状态机（loading/loaded/failed）
//  全部在 RemoteFilePeekSheet 内部，与本 modifier 解耦。
//

import SwiftUI

/// 远端文件 peek 展示 modifier。挂在 AIChatView 顶层，把 pendingRemoteFilePeek
/// 状态、MarkdownFilePeekRouter 监听、onChange → fullScreenCover 全部收敛一处。
struct RemoteFilePeekPresentationModifier: ViewModifier {
    @ObservedObject var vm: AIChatViewModel
    @State private var previewingRemoteFilePeek: RemoteFilePeekItem?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: MarkdownFilePeekRouter.tappedNotification)) { note in
                guard let info = note.userInfo,
                      let filePath = info[MarkdownFilePeekRouter.filePathKey] as? String,
                      !filePath.isEmpty else { return }
                vm.handleRemoteFilePeekTap(filePath: filePath)
            }
            .onChange(of: vm.pendingRemoteFilePeek) { newValue in
                if let item = newValue {
                    previewingRemoteFilePeek = item
                }
            }
            .fullScreenCover(item: $previewingRemoteFilePeek, onDismiss: {
                vm.pendingRemoteFilePeek = nil
            }) { item in
                RemoteFilePeekSheet(item: item)
            }
    }
}

extension View {
    /// 挂载远端文件 peek 展示链路：监听 MarkdownFilePeekRouter 通知 →
    /// vm.handleRemoteFilePeekTap → 弹 RemoteFilePeekSheet。
    /// 与 FilePreviewPanel（9a844c3）的 onChange/fullScreenCover 完全平行。
    func remoteFilePeekPresentation(vm: AIChatViewModel) -> some View {
        modifier(RemoteFilePeekPresentationModifier(vm: vm))
    }
}
