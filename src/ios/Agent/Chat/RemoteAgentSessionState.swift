import Combine
import Foundation

// MARK: - 远端 agent 会话状态（隔离架构铁律 2026-09-09）

/// 远端附件候选（Claude Code via bridge）。
/// 原为 AIChatViewModel 嵌套类型，随远端状态整体迁出（隔离架构铁律：
/// 远端类型不再住在本地 agent 主 VM 文件里）。
enum RemotePayload {
    case inlineImage(data: Data, mimeType: String)
    case uploadFile(fileURL: URL, fileName: String)
}

/// [M3] A Bridge `permission_request` awaiting the user's answer.
/// （原主 VM 文件尾部顶层类型，一并迁来。）
struct RemotePermissionRequest: Identifiable {
    let id: String          // toolUseId
    let toolName: String
    let input: [String: Any]
}

/// 远端 agent（CC Pocket bridge 通道）会话的 UI 状态 + 动作，独立于本地
/// agent 主 VM —— 隔离架构铁律（pp 2026-09-09）：远端 Agent 是扩展独立
/// 大模块，不得反向侵入或污染本地 Agent 的内部状态。
///
/// **生命周期不变式**：随 AIChatViewModel（per-session）常驻，VM init 即
/// 创建、永不为 nil —— 无创建/销毁时序问题，UI modifier 常驻挂载、无条件
/// 挂载引起的视图树重挂载问题。
///
/// **隔离 gate（写侧）**：写方法/字段只被三处调用 —— runAgentLoop 的
/// `as? RemoteAgentProvider` 分支、SSEStream 的远端事件 case、View 的远端
/// 动作点。本地 agent 会话从不写入 → 全部字段恒为初始空值 → 读侧天然零
/// 行为（与迁移前主 VM 上这些 @Published 的默认 nil 语义完全等价）。
///
/// **不持有 VM（防反向耦合）**：需要 VM 内部数据（sessionId / messages /
/// resolveCurrentEntry）的动作一律参数化，由调用点传入；本模块不 import、
/// 不引用 AIChatViewModel。
@MainActor
final class RemoteAgentSessionState: ObservableObject {
    private static let logger = AppLogger(category: "RemoteAgentState")

    /// 附件 inline 直传的 mime 集（随 RemotePayload 从主 VM 迁来）。
    static let kRemoteInlineMimeTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    // MARK: - 弹窗 / 预览（语义与迁移前逐一等价）

    /// [M3] Latest Bridge `permission_request` awaiting an answer, or nil.
    /// Drives the RemotePermissionDialog (non-bypass permission modes).
    @Published var pendingPermission: RemotePermissionRequest?

    /// 远端 agent 工具输出文件已下载到本地后，UI 层监听这个字段弹
    /// FilePreviewPanel 全屏面板。**仅远端 agent 用** —— 本地 agent 走
    /// OpenMinis 现有 minis:// 链接 / chip 路径。
    @Published var pendingAssistantPreview: URL?

    /// 远端 agent 正文文件路径点击后的预览内容，与 pendingAssistantPreview
    /// 分工明确：那个走「已下载本地文件」语义，这个走「按需读内容不落盘」语义。
    @Published var pendingRemoteFilePeek: RemoteFilePeekItem?

    // MARK: - 文件索引（正文路径可点击守门；ccpocket file_peek 对齐）

    /// 当前活跃远端 provider 的弱引用，为 file peek 提供 client/projectPath
    /// 通路（RemoteFileContentFetcher 构造需要）。仅 runAgentLoop 远端分支赋值。
    weak var activeProvider: RemoteAgentProvider?

    /// 远端 agent 项目文件后缀集快照（ccpocket file_peek 守门机制）。
    /// nil = 本地 agent / 无文件索引 = 正文路径不可点击。
    @Published private(set) var fileSuffixes: Set<String>?
    private var indexSuffixes: Set<String> = []
    private var observedFilePaths: Set<String> = []

    // MARK: - 附件候选交接

    /// 远端附件候选队列：send() 收集（仅当本轮走远端，见收集侧 gate），
    /// runAgentLoop 远端分支交给 provider 后清空。
    @Published var pendingPayloads: [RemotePayload] = []

    // MARK: - 远端压缩指示

    /// 远端 compacting 进行中（SSEStream .remoteCompactingStarted 写）。
    @Published var compacting = false

    // MARK: - 文件索引合成（纯逻辑，可单测）

    /// [Plan B3] tool-observed paths 并入（onFilePathsObserved 回调入口）。
    func mergeObservedFilePaths(_ paths: Set<String>) {
        observedFilePaths.formUnion(paths)
        rebuildFileSuffixes()
    }

    /// session 启动后拉 list_files 建后缀集（fire-and-forget，失败退化为
    /// 不可点击）。对齐 ccpocket file_peek_sheet.dart 加载 fileList 的时机。
    func refreshIndexSuffixes(from provider: RemoteAgentProvider) async {
        let entry = await provider.refreshFileIndex()
        indexSuffixes = entry?.suffixSet ?? []
        rebuildFileSuffixes()
    }

    /// list_files suffixes UNION tool-observed path forms。
    /// 空集 = nil（renderer 零行为语义不变）。
    private func rebuildFileSuffixes() {
        var merged = indexSuffixes
        for path in observedFilePaths {
            merged.formUnion(RemoteProjectFileIndex.observedPathForms(path))
        }
        fileSuffixes = merged.isEmpty ? nil : merged
    }

    // MARK: - 权限响应（id 匹配清理为纯函数，可单测）

    /// 仅当 pendingPermission 还是这条 request 时清空（响应乱序保护，
    /// 语义与迁移前 Task 内 if 判断一致）。
    func clearPermissionIfMatching(id: String) {
        if pendingPermission?.id == id {
            pendingPermission = nil
        }
    }

    // MARK: - 动作（全部参数化，不持有 VM）

    /// [M3] Answer the pending Bridge permission request. `allow` approves
    /// once, `always` approves for the whole session (official approve /
    /// approve_always / reject — ApprovalBar). Resolves the live client via
    /// RemoteAgentStore like every other remote action.
    func respondToPermission(
        _ request: RemotePermissionRequest,
        allow: Bool,
        always: Bool = false,
        sessionId: String?,
        resolveEntry: () -> ModelEntry?
    ) {
        guard let entry = resolveEntry() else {
            pendingPermission = nil
            return
        }
        guard let client = RemoteAgentStore.shared.existingClient(
            instanceID: entry.providerInstanceId,
            chatSessionID: sessionId
        ) else {
            pendingPermission = nil
            return
        }
        let kind = always ? "approve_always" : (allow ? "approve" : "reject")
        Task {
            await client.sendPermissionResponse(kind: kind, id: request.id)
            await MainActor.run {
                clearPermissionIfMatching(id: request.id)
            }
        }
    }

    // MARK: - 远端 agent 工具输出文件下载 (Claudio 2026-09-06)

    /// 在所有 messages 树里按 id 找 AssistantBlock（含流式块，已 commit/未
    /// commit 都搜）。工具块的 id 在转 AssistantBlock 时生成 UUID 持久。
    /// 纯函数（messages 由调用点传入 —— 不反向耦合 VM 内部状态）。
    static func findBlock(in messages: [ChatMessage], byId blockId: UUID) -> AssistantBlock? {
        for msg in messages {
            for block in msg.blocks where block.id == blockId { return block }
        }
        return nil
    }

    /// 卡片点 idle / failed：调 prepare_file_download → HTTP GET → 落 sandbox
    /// → 设 block.outputFileLocalPath + .ready → 自动设 pendingAssistantPreview。
    /// 状态机推进：idle → preparing → ready(.localPath) / failed(.code, .message)。
    /// 失败时设 outputFileDownloadState = .failed，UI 显示“点击重试”。
    func downloadAssistantBlockFile(
        blockId: UUID,
        sessionId: String?,
        resolveEntry: () -> ModelEntry?,
        messages: [ChatMessage]
    ) {
        guard let entry = resolveEntry() else { return }
        guard let client = RemoteAgentStore.shared.existingClient(
            instanceID: entry.providerInstanceId,
            chatSessionID: sessionId
        ) else { return }
        guard let block = Self.findBlock(in: messages, byId: blockId) else { return }
        guard let absPath = block.outputFileRemotePath else { return }
        // 已经在 .preparing / .downloading → 不重入
        switch block.outputFileDownloadState {
        case .preparing, .downloading:
            return
        default:
            break
        }
        let projectPath = RemoteAgentConnection.load(
            instanceID: entry.providerInstanceId
        )?.projectPath ?? ""
        guard !projectPath.isEmpty else {
            block.outputFileDownloadState = .failed(
                errorCode: "file_download_not_allowed",
                message: "No projectPath configured for this instance"
            )
            return
        }
        let suggestedName = (absPath as NSString).lastPathComponent
        let suggestedMime = block.outputFileMimeType
        let sizeHint = block.outputFileSizeBytes

        block.outputFileDownloadState = .preparing

        Task { [weak block] in
            do {
                let result = try await RemoteFileDownload.download(
                    client: client,
                    projectPath: projectPath,
                    absFilePath: absPath,
                    suggestedFileName: suggestedName,
                    suggestedMimeType: suggestedMime
                )
                await MainActor.run {
                    guard let block else { return }
                    block.outputFileLocalPath = result.localPath
                    if sizeHint == 0 { block.outputFileSizeBytes = result.sizeBytes }
                    if block.outputFileMimeType == nil {
                        block.outputFileMimeType = result.mimeType
                    }
                    block.outputFileDownloadState = .ready(localPath: result.localPath)
                    // 自动弹预览面板（pp 决策：下载完成 = 立即预览）
                    pendingAssistantPreview = URL(fileURLWithPath: result.localPath)
                    Self.logger.info(
                        "[FileDownload] ready block=\(block.id.uuidString.prefix(8)) bytes=\(result.sizeBytes)"
                    )
                }
            } catch let err as RemoteDownloadError {
                await MainActor.run {
                    guard let block else { return }
                    block.outputFileDownloadState = .failed(
                        errorCode: err.code,
                        message: err.message
                    )
                    Self.logger.warning(
                        "[FileDownload] failed block=\(block.id.uuidString.prefix(8)) code=\(err.code) msg=\(err.message)"
                    )
                }
            } catch {
                await MainActor.run {
                    guard let block else { return }
                    block.outputFileDownloadState = .failed(
                        errorCode: "file_download_failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// 卡片点 .ready：直接弹预览面板（不重复下载）。
    /// ready 状态已有 outputFileLocalPath，转 URL 设 pendingAssistantPreview。
    func requestPreviewAssistantBlock(blockId: UUID, messages: [ChatMessage]) {
        guard let block = Self.findBlock(in: messages, byId: blockId) else { return }
        guard case .ready(let localPath) = block.outputFileDownloadState else { return }
        pendingAssistantPreview = URL(fileURLWithPath: localPath)
    }

    /// [Claudio 2026-09-06] 处理远端 agent 正文文件路径点击
    /// （SelectableMarkdownView 里 .link = minis-file-peek:// URL 被
    /// shouldInteractWith 拦截后,MarkdownFilePeekRouter 发通知,AIChatView
    /// 监听通知调这个方法）。
    ///
    /// 对齐 ccpocket file_peek_sheet.dart openFilePeek：按路径调
    /// read_file / read_media_file，成功后弹 sheet。fetch 结果包装成
    /// RemoteFilePeekItem 赋给 pendingRemoteFilePeek，AIChatView 监听弹
    /// RemoteFilePeekSheet。
    ///
    /// gate：activeProvider 仅由 runAgentLoop 远端分支赋值 —— 非 nil =
    /// 本会话跑过远端回合（per-session 语义与原 lastAgentProviderIsRemote
    /// 双检等价，且本地会话恒 nil 直接短路）。
    func handleRemoteFilePeekTap(filePath: String) {
        guard let provider = activeProvider else { return }
        // 空路径 / 文件索引没命中过的路径直接忽略
        guard !filePath.isEmpty else { return }
        let fetcher = provider.makeFilePeekFetcher(filePath: filePath)
        let projectPath = provider.projectPath
        // fetch 在 RemoteFilePeekSheet 内部 .task 里执行（对齐 ccpocket
        // file_peek_sheet 自己在 initState 发请求 + 渲染 loading）。
        pendingRemoteFilePeek = RemoteFilePeekItem(
            filePath: filePath,
            projectPath: projectPath,
            fetcher: { try await fetcher.fetch() }
        )
    }
}
