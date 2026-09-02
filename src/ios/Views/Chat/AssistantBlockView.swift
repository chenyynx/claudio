import SwiftUI
import Combine

// MARK: - Assistant Block View (individual block — isolated invalidation)

struct AssistantBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onTapBlank: ((CGPoint) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// [T-selection-menu-minis-tts] Selection-menu read-aloud hooks, plumbed
    /// down to SelectableMarkdownView (nil for non-text or streaming contexts).
    var onReadAloud: (() -> Void)?
    var onSpeakText: ((String) -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var highlightedBlockId: UUID?
    @Binding var detailBlock: AssistantBlock?
    private var isHighlighted: Bool { highlightedBlockId == block.id }

    var body: some View {
        switch block.kind {
        case .text:
            if !block.content.isEmpty {
                textBlockView
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
                    )
            }
        case .thinking:
            ThinkingGrokRowView(
                block: block,
                isStreaming: isActiveMessage && message.blocks.last?.id == block.id,
                onOpenDetail: { detailBlock = block }
            )
            .padding(.vertical, 2)
        case .shellTool:
            ToolCapsuleView(block: block, icon: "terminal", accentColor: .green,
                            commandStartTime: commandStartTime, onStop: onStop, browserPool: browserPool,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .fileReadTool:
            ToolCapsuleView(block: block, icon: "doc.text", accentColor: .cyan,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .fileWriteTool:
            ToolCapsuleView(block: block, icon: "doc.text.fill", accentColor: .blue,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .fileEditTool:
            ToolCapsuleView(block: block, icon: "square.and.pencil", accentColor: .orange,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .browserTool:
            ToolCapsuleView(block: block, icon: "globe", accentColor: .blue,
                            commandStartTime: commandStartTime, onStop: onStop, browserPool: browserPool,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .readImageTool:
            ToolCapsuleView(block: block, icon: "photo", accentColor: .purple,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .memoryTool:
            ToolCapsuleView(block: block, icon: "brain.head.profile", accentColor: .pink,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .info:
            let allLines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            // Separate reason lines (⚠️) from the final switched line (✅)
            let reasonLines = allLines.filter { $0.hasPrefix("⚠️") }
            let switchedLine = allLines.first { !$0.hasPrefix("⚠️") && !$0.isEmpty }
            // Truncate middle if more than 9 reason lines
            let displayReasons: [String] = {
                if reasonLines.count <= 9 { return reasonLines }
                return Array(reasonLines.prefix(4)) + [String(localized: "⋯ \(reasonLines.count - 8) more")] + Array(reasonLines.suffix(4))
            }()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(displayReasons.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(ChatColors.primaryText.opacity(0.45))
                        .lineLimit(2)
                }
                if let switchedLine {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.8))
                        Text(switchedLine)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChatColors.primaryText.opacity(0.75))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.14), lineWidth: 0.5))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = block.content
                } label: {
                    Label(String(localized: "Copy Error"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private var textBlockView: some View {
        SelectableMarkdownView(
            markdown: block.content,
            cachedContent: block.cachedMarkdown,
            cachedAttributedString: block.cachedAttributedString,
            messageId: message.id,
            blockId: block.id,
            onTapBlank: onTapBlank,
            onCopyScreenshot: onCopyScreenshot,
            onReadAloud: onReadAloud,
            onSpeakText: onSpeakText
        )
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MinisOpenURLHandler())
    }
}

// MARK: - Shimmer Overlay (continuous diagonal shine via offset animation)

/// A diagonal shimmer band that sweeps from top-leading to bottom-trailing.
/// Uses a single stable gradient with an animated offset rather than rebuilding
/// gradient stops every frame — avoids a CAGradientLayer colorspace teardown
/// race during CATransaction flush (EXC_BAD_ACCESS at encode_colorspace).
struct ShimmerOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var offsetX: CGFloat = -1.0

    private var peakOpacity: CGFloat {
        colorScheme == .light ? 0.75 : 0.25
    }

    private func bell(_ x: CGFloat) -> CGFloat {
        exp(-4.5 * x * x)
    }

    private var stableStops: [Gradient.Stop] {
        let stepCount = 12
        let bandRadius: CGFloat = 0.40
        let center: CGFloat = 0.5
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: .white.opacity(0), location: 0))
        for i in 0...stepCount {
            let frac = CGFloat(i) / CGFloat(stepCount)
            let pos = center - bandRadius + frac * bandRadius * 2.0
            let dist = (pos - center) / bandRadius
            let alpha = bell(dist) * peakOpacity
            stops.append(.init(color: .white.opacity(Double(alpha)), location: pos))
        }
        stops.append(.init(color: .white.opacity(0), location: 1))
        return stops
    }

    var body: some View {
        GeometryReader { geo in
            let diag = geo.size.width + geo.size.height
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: stableStops,
                        startPoint: UnitPoint(x: 0, y: 1),
                        endPoint: UnitPoint(x: 1, y: 0)
                    )
                )
                .frame(width: diag, height: geo.size.height)
                .offset(x: offsetX * geo.size.width)
                .onAppear {
                    withAnimation(
                        .linear(duration: 2.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        offsetX = 1.0
                    }
                }
        }
        .clipped()
    }
}

// MARK: - Tool Capsule View (unified pill for all tool types)

struct ToolCapsuleView: View {
    @ObservedObject var block: AssistantBlock
    let icon: String
    let accentColor: Color
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var detailBlock: AssistantBlock?
    @State private var dotsActive = false
    /// [T-tool-bg-suspended-hint] Drives the background-suspension info alert.
    @State private var showBgHintAlert = false
    /// [T-ios-memory-write-revoke] Confirmation + result alerts for undoing a
    /// memory_write straight from the tool capsule's long-press menu.
    @State private var showRevokeMemoryAlert = false
    @State private var revokeMemoryResult: String?
    @State private var showRevokeMemoryResultAlert = false
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    /// Show the yellow ⓘ hint only when this tool was flagged as background-
    /// suspended AND enhanced background isn't already effective (nothing to
    /// suggest if it's on). Mirrors the BackgroundInterruptionTracker gate.
    private var showBgSuspendedHint: Bool {
        block.wasBackgroundSuspended && !keepAlive.enhancedBackgroundEffective
    }
    /// [T-ios-retry-hide-when-processing] Used to suppress the "Re-run From
    /// Here" long-press menu item while the agent loop is busy — tapping it
    /// mid-run would corrupt the in-flight processing state.
    @EnvironmentObject private var vm: AIChatViewModel

    /// [T-ios-memory-write-revoke] Whether this block is a `memory_write` that
    /// carries input args at all — the cheap check that decides whether the Undo
    /// menu item is offered. Deliberately does NOT parse the JSON: this feeds
    /// `ToolMenuKey`, which is rebuilt on every eager body pass, and re-running
    /// `JSONSerialization` there is exactly the per-frame work the menu gate
    /// exists to avoid. Other tools and `memory_get` never match.
    private var isRevocableMemoryWrite: Bool {
        guard case .memoryTool(let action) = block.kind, action == "memory_write" else { return false }
        guard let args = block.toolInputArgs else { return false }
        return !args.isEmpty
    }

    /// The text this block wrote to memory. Parsed lazily — only when the menu
    /// item is actually tapped — same treatment as `toolDetailsClipboard`.
    /// Nil when the args carry no non-empty `content` (e.g. a malformed or
    /// still-streaming tool call), which the confirm action treats as a no-op.
    private var memoryWriteContent: String? {
        guard case .memoryTool(let action) = block.kind, action == "memory_write" else { return nil }
        return MemoryWriteRevoker.writtenContent(fromToolInputArgs: block.toolInputArgs)
    }

    /// Display text: prefer LLM-generated toolSummary, fall back to toolDescription.
    private var displayText: String {
        if let summary = block.toolSummary, !summary.isEmpty {
            return summary
        }
        return block.toolDescription
    }

    /// [T-ios-tool-bubble-longpress-menu] Human-readable, paste-back-able
    /// dump of this tool call + its result for the "Copy Tool Details"
    /// menu action. Pulls tool name from the block kind, the input JSON
    /// from toolInputArgs (pretty-printed when it parses), and the result
    /// text + status from the block's content / toolStatus (with the
    /// snapshot text as a fallback source).
    private var toolDetailsClipboard: String {
        // Tool name from the block kind.
        let toolName: String
        switch block.kind {
        case .shellTool:     toolName = "shell_execute"
        case .fileReadTool:  toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool:  toolName = "file_edit"
        case .browserTool:   toolName = "browser_use"
        case .readImageTool: toolName = "read_image"
        case .memoryTool:    toolName = "memory"
        case .text, .thinking, .info: toolName = "unknown"
        }

        // Pretty-print the input JSON when possible; otherwise emit raw.
        let inputBlock: String
        if let raw = block.toolInputArgs, !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: pretty, encoding: .utf8) {
                inputBlock = prettyStr
            } else {
                inputBlock = raw
            }
        } else {
            inputBlock = "(no input captured)"
        }

        // Result text: prefer the live block content, fall back to the
        // snapshot text matched by toolUseId.
        var resultText = block.content
        if resultText.isEmpty, let tuId = block.toolUseId,
           let snap = toolSnapshots.first(where: { $0.id == tuId }) {
            resultText = snap.snapshot.text ?? ""
        }
        let hasScreenshot = block.imageFilePath != nil
            || (block.toolUseId.flatMap { tuId in toolSnapshots.first(where: { $0.id == tuId }) }?.snapshot.type == .image)

        // Status string.
        let statusStr: String
        switch block.toolStatus {
        case .success:   statusStr = "success"
        case .failed:    statusStr = "failed"
        case .cancelled: statusStr = "cancelled"
        case .running:   statusStr = "running"
        case .streaming: statusStr = "streaming"
        case .none:      statusStr = "unknown"
        }

        var resultMeta = "(\(resultText.count) chars, \(statusStr)"
        if hasScreenshot { resultMeta += ", screenshot" }
        resultMeta += ")"

        return """
        ## Tool Call
        name: \(toolName)
        id: \(block.toolUseId ?? "(none)")
        input:
        \(inputBlock)

        ## Tool Result
        \(resultMeta)
        \(resultText)
        """
    }

    private var isStreaming: Bool {
        if case .streaming = block.toolStatus { return true }
        return false
    }

    private var isActive: Bool {
        switch block.toolStatus {
        case .streaming, .running: return true
        default: return false
        }
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                // Status indicator / icon
                statusOrIcon

                // Description text with bouncing dots during streaming
                HStack(spacing: 0) {
                    Text(displayText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                    if isStreaming {
                        ForEach(0..<3, id: \.self) { i in
                            Text(".")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ChatColors.primaryText)
                                .offset(y: dotsActive ? -2 : 1)
                                .animation(
                                    .easeInOut(duration: 0.35)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.12),
                                    value: dotsActive
                                )
                        }
                    }
                }
                .lineLimit(1)

                // Execution duration (shown after completion). The HH:mm:ss
                // start time is surfaced inside the detail view's bottom bar
                // (ToolLiveSheet.bottomBar) instead of here — the inline
                // pill list stays clean.
                if let dur = durationText {
                    Text(dur)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }

                // Stop button for running commands
                if case .running = block.toolStatus {
                    Button {
                        onStop?()
                    } label: {
                        // Visual: 10×10 red square unchanged. Hit area enlarged to
                        // 24×24 via an expanded contentShape, while the negative
                        // padding pins the *layout* footprint back to 18×18 so the
                        // capsule width/height is identical to before.
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .padding(-3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color(UIColor.systemGray6))
            .clipShape(Capsule())
            .overlay(
                Group {
                    if isActive {
                        ShimmerOverlay()
                            .clipShape(Capsule())
                            .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(ChatColors.toolBorder, lineWidth: 0.5)
            )
            .contentShape(Capsule())
            .onTapGesture {
                detailBlock = block
            }
            .contextMenu {
                // [T-ios-msg-contextmenu-recursion-crash] Gate the eager menu
                // tree behind an Equatable key so this tool cell's body churn
                // during `gh`/shell streaming doesn't rebuild + re-diff the menu
                // subtree every frame (part of the deep ContextMenuModifier
                // recursion in incident 98E8805F). `toolDetailsClipboard` is read
                // lazily at TAP time, so the key only tracks structure: the tool
                // (blockId), whether the Re-run branch is shown (isProcessing),
                // and whether the memory-Undo branch is shown. All three are
                // cheap reads — the expensive payloads (clipboard dump, written
                // memory text) are built at tap time, never in the key.
                EquatableMenuGate(key: ToolMenuKey(
                    blockId: block.id,
                    isProcessing: vm.isProcessing,
                    canRevokeMemoryWrite: isRevocableMemoryWrite
                )) {
                    // [T-ios-tool-bubble-longpress-menu]
                    Button {
                        UIPasteboard.general.string = toolDetailsClipboard
                    } label: {
                        Label(String(localized: "Copy Tool Details"), systemImage: "doc.on.doc")
                    }
                    // [T-ios-retry-hide-when-processing] Only expose the
                    // destructive Re-run action when the agent loop is idle.
                    // Re-running mid-stream would tear down an in-flight turn
                    // and confuse downstream state — hide both the divider and
                    // the button as a group so the menu doesn't leave a
                    // trailing separator with nothing under it.
                    if !vm.isProcessing {
                        Divider()
                        Button(role: .destructive) {
                            // Re-run the whole assistant turn that owns this
                            // tool_use. Routed via notification so we don't have
                            // to thread a vm closure through the 4-layer cell
                            // hosting chain — AIChatView's RerunFromToolBlockListener
                            // maps blockId → owning assistant msg → preceding user
                            // msg → vm.retryFromMessage.
                            NotificationCenter.default.post(
                                name: .rerunFromToolBlock,
                                object: nil,
                                userInfo: ["blockId": block.id]
                            )
                        } label: {
                            Label(String(localized: "Re-run From Here"), systemImage: "arrow.clockwise")
                        }
                    }
                    // [T-ios-memory-write-revoke] Undo the daily-log entry this
                    // memory_write produced, without a detour through
                    // Memories in Session → detail sheet. Only appears for a
                    // memory_write that carries input args.
                    if isRevocableMemoryWrite {
                        Divider()
                        Button(role: .destructive) {
                            showRevokeMemoryAlert = true
                        } label: {
                            Label(String(localized: "Undo This Memory Write"), systemImage: "trash.slash")
                        }
                    }
                }
                .equatable()
            }
            // [T-tool-bg-suspended-hint] Yellow ⓘ just outside the capsule's
            // trailing edge when this tool was likely suspended by the OS in the
            // background. Tapping shows an alert offering to enable enhanced
            // background (deep-links to Settings → Permissions → Background).
            if showBgSuspendedHint {
                Button {
                    showBgHintAlert = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .accessibilityLabel(Text(String(localized: "Background suspension info")))
            }
            Spacer(minLength: 0)
        }
        .alert(
            String(localized: "Task may have been paused"),
            isPresented: $showBgHintAlert
        ) {
            Button(String(localized: "Go Enable")) {
                // Deep-link to Settings → Permissions → Background, nudging the
                // recommended rows ON — they highlight only while still OFF
                // (= minis://settings/background?focus=…:true,…:true). Location
                // Tracking is included so the background heartbeat that keeps the
                // task Live Activity refreshing in real time gets enabled too.
                DeepLinkCoordinator.shared.setFocus(
                    rawQueryValue: "enhancedBackgroundExecution:true,backgroundSpeakEnabled:true,locationTrackingEnabled:true")
                DeepLinkCoordinator.shared.pendingSettingsTarget = .background
            }
            Button(String(localized: "Maybe Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "This tool may have been paused by the system while running in the background. Enable enhanced background execution to improve background task reliability."))
        }
        // [T-ios-memory-write-revoke] Mirrors the Revoke Memory confirmation in
        // SessionMemoryView: confirm, then report the outcome in place — the
        // user stays in the transcript, no navigation. The bubble itself is
        // left alone; only the underlying daily-log file changed.
        .alert(
            String(localized: "Revoke Memory"),
            isPresented: $showRevokeMemoryAlert
        ) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Revoke"), role: .destructive) {
                // The menu item is gated on the cheap enum+args check, so the
                // `content` parse can still come back empty here (malformed or
                // still-streaming args). Report that rather than failing silently.
                if let written = memoryWriteContent {
                    revokeMemoryResult = MemoryWriteRevoker.revoke(writtenContent: written)
                } else {
                    revokeMemoryResult = String(localized: "No written content to revoke.")
                }
                showRevokeMemoryResultAlert = true
            }
        } message: {
            Text(String(localized: "Remove this memory entry from the daily log? This cannot be undone."))
        }
        .alert(revokeMemoryResult ?? "", isPresented: $showRevokeMemoryResultAlert) {
            Button(String(localized: "OK")) {}
        }
        .onChange(of: isStreaming) { streaming in
            dotsActive = streaming
        }
        .onAppear {
            if isStreaming {
                dotsActive = true
            }
        }
    }

    // MARK: - Status / Icon

    @ViewBuilder
    private var statusOrIcon: some View {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(iconColor)
    }

    private var iconColor: Color {
        switch block.toolStatus {
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        default: return accentColor
        }
    }

    /// Formatted execution duration (e.g. "1.2s", "45s", "2m 10s").
    private var durationText: String? {
        guard let dur = block.toolDuration else { return nil }
        if dur < 1 { return String(format: "%.1fs", dur) }
        if dur < 60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return "\(mins)m \(secs)s"
    }

}



extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
    /// Posted when a long-press selection menu's "Add to Chat Input" action
    /// fires. userInfo["text"] is the selected text to append. The active
    /// chat's AIChatView listens and forwards to `vm.appendToInputText`.
    static let chatInputAppendRequested = Notification.Name("chatInputAppendRequested")
    /// Posted when an inline media attachment (image / video thumbnail /
    /// audio waveform) finishes async loading and its intrinsic content
    /// size changes. The collection view listens and invalidates self-sizing
    /// caches so cells re-measure. notification.object is the source URL
    /// string (for logging only — handler invalidates all visible cells).
    /// [T-attachment-size-invalidate 2026-05-21]
    static let minisAttachmentSizeChanged = Notification.Name("minisAttachmentSizeChanged")
    /// Posted from a tool capsule's long-press menu "Re-run from here".
    /// userInfo["blockId"] is the AssistantBlock.id (UUID) of the tapped
    /// tool_use. The active AIChatView listens, maps the block to its
    /// owning assistant message, finds the preceding user message, and
    /// re-runs the agent loop from there. [T-ios-tool-bubble-longpress-menu]
    static let rerunFromToolBlock = Notification.Name("rerunFromToolBlock")
}

/// Listens for `.rerunFromToolBlock` and drives the re-run. Extracted into
/// its own ViewModifier (like ChatInputAppendListener) to keep AIChatView's
/// body within the Swift type-checker budget. [T-ios-tool-bubble-longpress-menu]
///
/// "Re-run from here" semantics (block boundary —
/// T-ios-rerun-from-tool-block-position): re-run from the exact point this
/// tool_use was about to be issued. retryFromToolBlock keeps the blocks
/// BEFORE the target tool_use within its assistant turn, drops the target
/// block + later blocks in that turn + all later messages (rewriting the
/// trimmed assistant row in the DB), then re-runs the agent loop. If the
/// target is the first block with nothing preceding it, that path degrades
/// to a preceding-user-message truncation automatically.
struct RerunFromToolBlockListener: ViewModifier {
    let vm: AIChatViewModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .rerunFromToolBlock)) { note in
            guard let blockId = note.userInfo?["blockId"] as? UUID else { return }
            vm.retryFromToolBlock(blockId: blockId)
            vm.forceScrollToBottom.send()
        }
    }
}

/// View-modifier wrapper around the `chatInputAppendRequested` listener.
/// Extracted out of AIChatView.body because that body sits at the Swift
/// type-checker's expression budget and inlining another `.onReceive` block
/// trips the "compiler unable to type-check this expression in reasonable
/// time" diagnostic.
/// Listens for `.dismissAllImmersivePresentations` and calls the host
/// view's clear method. Extracted into its own modifier so AIChatView's
/// body type stays demangleable — adding the onReceive directly to body
/// trips the Swift type-checker timeout (same class of issue as the
/// 2026-04-17 inputBar / 2026-05-24 attachmentMenu blow-ups).
struct DismissImmersiveCoversListener: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .dismissAllImmersivePresentations)) { _ in
            onDismiss()
        }
    }
}

struct ChatInputAppendListener: ViewModifier {
    let vm: AIChatViewModel
    @Binding var inputFocused: Bool

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .chatInputAppendRequested)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            vm.appendToInputText(text)
            // Focus the composer + pop the keyboard so the user can
            // immediately continue typing after a long-press → Add to Chat
            // Input. Independent of the post-reply auto-pop Settings
            // toggle (#354 / eb6d8164) — that gate is for *passive*
            // moments (reply finished, scroll, etc.); this is a direct
            // user gesture and should always focus. (T-add-to-input-focus)
            //
            // Async hop so the inputText `didSet` settles into the
            // composer's TextField before the focus binding flips —
            // without it the keyboard occasionally pops first and the
            // text appears mid-animation.
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotOffsets: [Bool] = [false, false, false]
    /// Live Soul name so the indicator reads "<custom name> is thinking…" when
    /// the user has renamed the assistant in Soul settings. Updates via
    /// `.soulMdChanged` Notification — same wiring used by `AssistantSoulName`.
    @State private var soulName: String = {
        let n = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Minis" : n
    }()

    var body: some View {
        // The thinking-level badge that used to trail this indicator was
        // removed — the nav-bar title (AIChatView.thinkingLevelBadge) is now
        // the single place that shows and changes the thinking level, so a
        // duplicate here was redundant. ThinkingLevelSheetView is unchanged;
        // it's still presented from the nav-bar badge.
        HStack(spacing: 0) {
            Text("\(soulName) is thinking")
            ForEach(0..<3, id: \.self) { i in
                Text(".")
                    .offset(y: dotOffsets[i] ? -3 : 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            let n = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            soulName = n.isEmpty ? "Minis" : n
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.top, 0)
        .onAppear {
            for i in 0..<3 {
                withAnimation(
                    .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15)
                ) {
                    dotOffsets[i] = true
                }
            }
        }
    }
}

// MARK: - Thinking Level Sheet

struct ThinkingLevelSheetView: View {
    let currentLevel: ThinkingLevel
    let availableLevels: [ThinkingLevel]
    let onSelect: (ThinkingLevel) -> Void

    var body: some View {
        NavigationStack {
            List {
                thinkingRow(level: .off, isSelected: !currentLevel.isEnabled)
                Section {
                    ForEach(availableLevels, id: \.self) { level in
                        thinkingRow(level: level, isSelected: currentLevel == level)
                    }
                }
            }
            .navigationTitle(String(localized: "Thinking Intensity"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func thinkingRow(level: ThinkingLevel, isSelected: Bool) -> some View {
        Button {
            onSelect(level)
        } label: {
            HStack {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .opacity(level == .off ? 0.4 : 1.0)
                Text(level.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Tool Copy Button

private struct ToolCopyButton: View {
    var accentColor: Color = .green
    let content: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = content()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 16, height: 16)
                .foregroundStyle(copied ? accentColor : accentColor.opacity(0.4))
        }
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}
