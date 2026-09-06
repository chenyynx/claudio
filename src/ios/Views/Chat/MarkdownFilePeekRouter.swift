//
//  MarkdownFilePeekRouter.swift
//  MinisApp
//
//  远端 agent 正文文件路径点击 → 预览面板的通知路由（ccpocket file_peek
//  openFilePeek 的 App 端转发机制）。
//
//  对齐 ccpocket 官方：apps/mobile/lib/features/file_peek/file_peek_sheet.dart
//  `openFilePeek` 被 inline syntax 注册的文件链接点击调用，弹
//  showFilePeekSheet。claudio 端 SelectableMarkdownView 的
//  shouldInteractWith 拦截 `minis-file-peek://` URL，调
//  MarkdownFilePeekRouter.postTap 发通知；AIChatView .onReceive 监听
//  后弹 RemoteFilePeekSheet 全屏面板。
//
//  路由用 NotificationCenter + Router（沿用 MarkdownImageTapRouter
//  同款模式，避免在 7474 行的 SelectableMarkdownView 里持有 view
//  model 引用导致循环依赖 + 单测困难）。
//

import Foundation

/// 远端文件路径点击通知路由。
/// - `filePath`: 用户点击的路径（反引号内或裸路径，命中后缀集守门）
/// - `projectPath`: 当前远端 session 的项目路径，调用方在 post 时附带
enum MarkdownFilePeekRouter {
    static let tappedNotification = Notification.Name("MarkdownFilePeekTappedNotification")
    static let filePathKey = "filePath"
    static let projectPathKey = "projectPath"

    static func postTap(filePath: String, projectPath: String) {
        NotificationCenter.default.post(
            name: tappedNotification,
            object: nil,
            userInfo: [filePathKey: filePath, projectPathKey: projectPath]
        )
    }
}
