//
//  RemoteProjectFileIndex.swift
//  MinisApp
//
//  远端 agent 项目文件索引 + 后缀集（ccpocket file_peek 守门机制）。
//
//  对齐 ccpocket 官方实现：
//  - apps/mobile/lib/features/file_peek/file_path_syntax.dart `buildSuffixSet` / `cachedSuffixSet`
//  - apps/mobile/lib/providers/bridge_cubits.dart `FileListCubit`
//  - apps/mobile/lib/services/bridge_service.dart `requestProjectFileList`
//  - packages/bridge/src/websocket.ts:6147 `list_files` RPC
//
//  作用：SelectableMarkdownView 识别正文里反引号内 + 裸路径时，查这个
//  索引的后缀集「是否命中真实文件列表」。**没有它就变不可点击**——
//  ccpocket 靠这个压误报（URL / 版本号 / 普通带点文字不会被误认成文件
//  路径）。
//
//  并发：actor 保护缓存。refresh 是 fire-and-forget；snapshot 是
//  async-await 返回不可变快照（RemoteFileIndexEntry 是 Sendable）。
//  UI 层在 .task 里 await snapshot 拿 suffixSet，同步渲染时直接
//  Set<String>.contains()——零跨 actor 阻塞。
//

import Foundation

/// 单项目文件索引条目。Sendable 不可变快照，UI 可直接持有渲染。
/// files = 项目内相对路径列表（与桥 list_files 回包一致）；
/// modifiedAt = path → Unix 秒；suffixSet = 预计算的所有后缀
/// （lib/models/msg.dart → lib/models/msg.dart / models/msg.dart /
/// msg.dart），用于 O(1) 后缀匹配。
struct RemoteFileIndexEntry: Sendable, Equatable {
    let files: [String]
    let modifiedAt: [String: Double]
    let suffixSet: Set<String>
    let fetchedAt: Date

    static func buildSuffixSet(from files: [String]) -> Set<String> {
        var suffixes: Set<String> = []
        suffixes.reserveCapacity(files.count * 3)
        for filePath in files {
            guard !filePath.hasSuffix("/") else { continue }
            let parts = filePath.split(separator: "/")
            for i in 0..<parts.count {
                suffixes.insert(parts[i...].joined(separator: "/"))
            }
        }
        return suffixes
    }

    /// [Claudio 2026-09-07] 把相对后缀集合并进 `{root}/{相对形态}` 绝对
    /// 路径形态 — agent 正文引用文件常用绝对路径（/home/ubuntu/claudio/
    /// README.md），而 buildSuffixSet 只产出相对形态，matches() 不命中
    /// → 路径不可点击。root 为空时原样返回（无绝对形态可造）。
    static func mergingAbsoluteForms(_ suffixes: Set<String>, projectRoot: String) -> Set<String> {
        let root = projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
        guard !root.isEmpty, !suffixes.isEmpty else { return suffixes }
        var merged = suffixes
        merged.reserveCapacity(suffixes.count * 2)
        for s in suffixes {
            merged.insert(root + "/" + s)
        }
        return merged
    }
}

/// 远端 agent 项目文件索引单例。actor 保护：后台 task 调 refresh
/// 串行化更新缓存；UI 层 await snapshot 拿不可变 Sendable 快照同步
/// 渲染。
actor RemoteProjectFileIndex {
    static let shared = RemoteProjectFileIndex()

    private var index: [String: RemoteFileIndexEntry] = [:]

    /// 在途 refresh 集合（per projectPath 防重入）。ccpocket 也有同样
    /// 防重入（bridge_service.dart `_latestFileListRequestIdsByProject`）。
    private var inFlight: Set<String> = []

    private nonisolated static let logger = AppLogger(category: "RemoteFileIndex")

    private init() {}

    /// 拉取文件列表。fire-and-forget：失败仅 debug log，不抛错——无文件
    /// 列表时退化为「路径不可点击」，不影响其他功能。
    func refresh(projectPath: String, client: CCPocketClient) async {
        guard !inFlight.contains(projectPath) else { return }
        inFlight.insert(projectPath)
        defer { inFlight.remove(projectPath) }

        do {
            let payload = try await client.listFiles(projectPath: projectPath)
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try JSONDecoder().decode(CCPocketProtocol.FileListResponse.self, from: data)
            let files = response.files ?? []
            let modifiedRaw = response.modifiedAt ?? [:]
            // [Claudio 2026-09-07] 绝对路径形态一并入集：agent 正文里
            // 引用文件常用绝对路径（/home/ubuntu/claudio/README.md），
            // 而 buildSuffixSet 产出的是项目相对形态（claudio/README.md）
            // —— matches() 只查集合成员，绝对形态不命中 → 路径不可点击。
            // 在 refresh 一次性合并，matches/渲染调用点零改动。
            let suffixSet = RemoteFileIndexEntry.mergingAbsoluteForms(
                RemoteFileIndexEntry.buildSuffixSet(from: files),
                projectRoot: projectPath
            )
            let entry = RemoteFileIndexEntry(
                files: files,
                modifiedAt: modifiedRaw,
                suffixSet: suffixSet,
                fetchedAt: .now
            )
            index[projectPath] = entry
        } catch {
            Self.logger.warning(
                "refresh failed projectPath=\(projectPath): \(error.localizedDescription)"
            )
        }
    }

    /// 拿当前缓存的不可变快照。UI 在 .task 里 await 这个，缓存到
    /// @State 同步渲染（suffixSet 是 Set<String> Sendable，可跨 actor
    /// 安全传递）。nil 表示从未拉过。
    func snapshot(projectPath: String) -> RemoteFileIndexEntry? {
        index[projectPath]
    }

    /// 清空（连接断开 / 切换会话时调用）。
    func reset() {
        index.removeAll()
    }

    // MARK: - Static helpers（非 actor 隔离，renderInline hot path 可直接调）

    /// 行号后缀 `:42` / `:42:10` 剥除。对齐 ccpocket file_path_syntax.dart
    /// `_stripLineCol` + `_lineColPattern`。
    nonisolated static let lineColPattern = /^(:\d+){1,2}$/

    nonisolated static func stripLineCol(_ text: String) -> String {
        guard text.contains(lineColPattern) else { return text }
        return text.replacing(lineColPattern, with: "")
    }

    /// 后缀集匹配核心（exact 或 stripped 命中）。纯静态，renderInline hot
    /// path 调用零开销。
    /// [Plan B3 2026-09-07] Suffix forms for a tool-observed file path.
    /// "/home/ubuntu/claudio/README.md" -> absolute original + all tail
    /// combos ("claudio/README.md", "README.md", ...). Relative input works
    /// too ("claudio/README.md" -> original + "README.md"). Pure, testable.
    nonisolated static func observedPathForms(_ raw: String) -> Set<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var forms: Set<String> = [trimmed]
        let cleaned = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let parts = cleaned.split(separator: "/").map(String.init)
        if parts.count > 1 {
            for i in 1..<parts.count {
                forms.insert(parts[i...].joined(separator: "/"))
            }
        }
        return forms
    }

    nonisolated static func matches(path: String, suffixSet: Set<String>) -> Bool {
        if suffixSet.contains(path) { return true }
        let stripped = stripLineCol(path)
        if stripped != path, suffixSet.contains(stripped) { return true }
        return false
    }
}
