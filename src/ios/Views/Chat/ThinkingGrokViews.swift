import SwiftUI

// MARK: - Grok 式思考块（pp 拍板 2026-09-02 · demo: shared/claudio/grok-thinking-demo.html）
//
// 思考中：红色 3×3 像素块错相呼吸 + "Thinking" 扫光 + "· N 秒" 实时计时。
// 结束：呼吸停止 → 静态方块定格（保留静态辉光），文案 "Thought for Ns"。
// 点击：底部弹层（图三）衬线思考全文；思考中打开可看实时流。
// 取代旧 ThinkingBlockView（内联展开）；AssistantBlock.isThinkingExpanded 保留但不再使用。

/// 颜色与呼吸参数 — 与 agent-flow 组件（AgentFlowView.swift CELL_D / CELL_DL）一一对应。
enum ThinkingGrokStyle {
    /// #ef4444
    static let accent = Color(red: 0xEF / 255.0, green: 0x44 / 255.0, blue: 0x44 / 255.0)
    /// rgba(239,68,68,.65) 辉光
    static let glow = Color(red: 0xEF / 255.0, green: 0x44 / 255.0, blue: 0x44 / 255.0, opacity: 0.65)
    static let textGray = Color(UIColor.systemGray)
    /// 每格呼吸周期（秒）
    static let cellPeriod: [Double] = [2.2, 1.8, 2.6, 1.9, 2.4, 1.7, 2.1, 1.8, 2.5]
    /// 每格错相延迟（秒）
    static let cellPhase: [Double] = [0, 0.65, 1.35, 0.3, 1.05, 0.85, 1.5, 0.15, 0.95]
    /// 扫光周期（秒）
    static let shimmerPeriod = 1.7
}

/// 3×3 像素块图标：思考中错相呼吸，结束定格为静态方块。
/// 呼吸用 TimelineView 20fps 驱动（HTML 原型为 CSS 无限循环）；9 个小矩形的重绘开销可忽略。
struct ThinkingPixelIcon: View {
    let animating: Bool

    var body: some View {
        Group {
            if animating {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
                    grid(now: ctx.date, animating: true)
                }
            } else {
                grid(now: .now, animating: false)
            }
        }
    }

    private func grid(now: Date, animating: Bool) -> some View {
        VStack(spacing: 1.25) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 1.25) {
                    ForEach(0..<3, id: \.self) { col in
                        cell(index: row * 3 + col, now: now, animating: animating)
                    }
                }
            }
        }
        .frame(width: 28, height: 28)
    }

    /// HTML breathe 关键帧：0%/100% = opacity 1 · scale 1；50% = opacity .22 · scale .88。
    private func cell(index: Int, now: Date, animating: Bool) -> some View {
        let period = ThinkingGrokStyle.cellPeriod[index]
        let raw = animating
            ? (now.timeIntervalSinceReferenceDate + ThinkingGrokStyle.cellPhase[index])
                .truncatingRemainder(dividingBy: period) / period
            : 0.0
        let breath = animating ? 0.5 - 0.5 * cos(raw * 2 * .pi) : 0.0   // 0=满格 1=最暗
        return RoundedRectangle(cornerRadius: 2)
            .fill(ThinkingGrokStyle.accent.opacity(animating ? 1.0 - 0.78 * breath : 1.0))
            .frame(width: 8.5, height: 8.5)
            .scaleEffect(animating ? 1.0 - 0.12 * breath : 1.0)
            .shadow(color: ThinkingGrokStyle.glow, radius: 2.5)
    }
}

/// "Thinking" 扫光：高光从左向右循环（HTML: background-clip 渐变位移，只挂词本身）。
struct ThinkingShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let p = ctx.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: ThinkingGrokStyle.shimmerPeriod)
                / ThinkingGrokStyle.shimmerPeriod
            let center = 0.15 + 0.7 * p   // 高光中心限制在 0.15…0.85，避免端点硬切
            Text(text)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: ThinkingGrokStyle.textGray, location: max(0, center - 0.25)),
                            .init(color: .white, location: center),
                            .init(color: ThinkingGrokStyle.textGray, location: min(1, center + 0.25)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        }
    }
}

/// 聊天流里的思考行（替代旧 ThinkingBlockView 内联展开——点击改为弹 sheet）。
struct ThinkingGrokRowView: View {
    @ObservedObject var block: AssistantBlock
    let isStreaming: Bool
    var onOpenDetail: () -> Void

    var body: some View {
        Button(action: onOpenDetail) {
            HStack(spacing: 10) {
                ThinkingPixelIcon(animating: isStreaming)
                if isStreaming {
                    ThinkingShimmerText(text: "Thinking")
                    Text("·")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(UIColor.systemGray3))
                    ThinkingElapsedLabel(startTime: block.thinkingStartTime)
                    Spacer(minLength: 0)
                } else {
                    Text(doneTitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ThinkingGrokStyle.textGray)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ThinkingGrokStyle.textGray)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibilityLabel(isStreaming ? "Thinking" : doneTitle)
    }

    /// 时长未打点（历史恢复块）→ 无秒数，只显示 "Thought"。
    private var doneTitle: String {
        block.thinkingDuration.map { "Thought for \(Int($0.rounded()))s" } ?? "Thought"
    }
}

/// "· N 秒" 实时计时 — TimelineView 每秒刷新，起点取流层打点的 thinkingStartTime。
private struct ThinkingElapsedLabel: View {
    let startTime: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("\(elapsed) 秒")
                .font(.system(size: 15))
                .foregroundStyle(ThinkingGrokStyle.textGray)
                .monospacedDigit()
        }
    }

    private var elapsed: Int {
        startTime.map { max(0, Int(Date.now.timeIntervalSince($0))) } ?? 0
    }
}

/// 图三式底部弹层：grabber + 白圆返回钮 + 居中标题 + 衬线思考全文。
/// 思考中打开可看实时流（尾部 12K 窗口 + 光标），结束后定格全文。
struct ThinkingDetailSheetView: View {
    @ObservedObject var block: AssistantBlock
    /// 打开时刻捕获的流式判定；时长冻结后视图优先用 thinkingDuration（闭包只补直播窗口）。
    let isStreamingProvider: () -> Bool
    @Environment(\.dismiss) private var dismiss
    /// 流式正文尾部窗口（字符）— 超大思考的防抖策略，sheet 无滚动跟随需求所以比旧内联视图小。
    private let tailWindow = 12_000

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            ScrollViewReader { proxy in
                ScrollView {
                    Text(sheetText)
                        .font(.system(size: 19, design: .serif))
                        .lineSpacing(7)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                        .padding(.bottom, 44)
                        .id("thinkingSheetBottom")
                }
                .onChange(of: block.content) { _ in
                    guard isStreamingNow else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("thinkingSheetBottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(UIColor.systemGray6))
        .onAppear { block.flushThinkingBuffer() }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color(UIColor.systemGray3))
            .frame(width: 38, height: 5)
            .padding(.top, 8)
    }

    private var isStreamingNow: Bool { block.thinkingDuration == nil && isStreamingProvider() }

    private var title: String {
        if let d = block.thinkingDuration { return "Thought for \(Int(d.rounded()))s" }
        return isStreamingNow ? "Thinking · \(elapsed) 秒" : "Thought"
    }

    private var elapsed: Int {
        block.thinkingStartTime.map { max(0, Int(Date.now.timeIntervalSince($0))) } ?? 0
    }

    private var sheetText: String {
        var text = block.content
        if isStreamingNow && text.count > tailWindow {
            text = "… Showing last \(tailWindow / 1000)K of \(text.count / 1000)K characters\n\n"
                + String(text.suffix(tailWindow))
        }
        return isStreamingNow ? text + " ▍" : text
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ZStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 33, height: 33)
                            .background(Circle().fill(Color(UIColor.systemBackground)))
                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 10)
        }
    }
}
