//
//  AskQuestionCardView.swift
//  流内 AskUserQuestion 卡片（v3 设计稿 SwiftUI 实现）。
//
//  设计基准：shared/claudio-design/ask-user-question-card-v3.html
//  - 四态：pending / answered / skipped / expired（状态由外部传入，视图不自持回合状态）
//  - A 分页：PageView + 分段进度条（绿已答 / 橙当前 / 灰未到）
//  - multiSelect：圆角方块 checkbox + 确认胶囊（armed 态 35%→100%）
//  - Claude 版视觉语言吸收：checkbox/确认胶囊/折叠摘要（AnsweredSummaryView 胶囊链）
//  - livedot：橙 6pt breath 2.4s 明暗呼吸（pending 活性信号；答/跳/失效即消失）
//
//  [隔离] 纯展示组件；答题动作经回调上抛（answer/skip 由 RemoteAgentSessionState
//  发 wire 消息）。状态外提：本视图不写 ChatStore / VM —— cell 复用安全。
//

import SwiftUI

// MARK: - Card container

/// 流内问题卡。卡片宽 = 消息流内全宽（与 tool 卡同族，由 cell 布局决定，
/// 本视图不自带水平 margin）。
struct AskQuestionCardView: View {
    let payload: AskWirePayload
    /// 生命周期状态：pending = 可交互；其余 = 定格只读。
    let status: AskCardStatus
    /// 当前翻到的页（A 分页；单题卡忽略）。
    @Binding var page: Int
    /// 单选点击 / multiSelect 确认键 → 提交全部答案。
    let onSubmit: ([String: String]) -> Void
    /// 跳过（cancel 回合）。仅 pending 显示。
    let onSkip: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var palette: AskPalette { .init(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if payload.questions.count > 1 {
                AskStepper(count: payload.questions.count, page: page, statuses: perPageStatus)
            }

            TabView(selection: $page) {
                ForEach(Array(payload.questions.enumerated()), id: \.offset) { idx, q in
                    AskQuestionPage(
                        question: q,
                        index: idx,
                        total: payload.questions.count,
                        status: status,
                        palette: palette,
                        onPick: { label in pick(idx: idx, question: q, label: label) },
                        onToggle: { label in toggle(idx: idx, question: q, label: label) },
                        onConfirm: { confirm(question: q) }
                    )
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: payload.questions.count > 1 ? .automatic : .never))
            .frame(height: pageSize)

            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 8)
    }

    // MARK: pieces

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerHint)
                .font(.system(size: 11))
                .foregroundStyle(palette.ink3)
            Spacer(minLength: 8)
            if status.isPending {
                AskSkipButton(palette: palette) { onSkip() }
            }
        }
    }

    private var footerHint: String {
        switch status {
        case .pending:
            payload.questions.count > 1
                ? "回答问题（\(pageLabel)），或直接输入将排队"
                : "回答问题，或直接输入（将排队发送）"
        case .answered: "已回答"
        case .skipped: "已跳过 · 未回答"
        case .expired: "回合已结束 · 未回答"
        }
    }

    private var pageLabel: String { "\(page + 1) / \(payload.questions.count)" }

    private var perPageStatus: [AskCardStatus] {
        // 分段进度条颜色：answered 全绿；skipped/expired 对应灰；pending 橙。
        Array(repeating: status, count: payload.questions.count)
    }

    // MARK: layout

    /// 页高：选项行 ~58pt（含说明一行）+ 题头 ~34pt + 间距。multiSelect 确认键 +40。
    private var pageSize: Double {
        let base = maxPageOptionCount * 58 + 104
        let confirm = hasMultiSelect ? 40.0 : 0.0
        return base + confirm
    }

    private var maxPageOptionCount: Int {
        payload.questions.map { $0.options.count }.max() ?? 0
    }

    private var hasMultiSelect: Bool {
        payload.questions.contains { $0.multiSelect }
    }

    // MARK: local answer state（复用安全：pending 期间交互态；提交后由 status 定格）

    @State private var picks: [String: String] = [:]        // 单选：answerKey → label
    @State private var multiPicks: [String: Set<String>] = [:] // answerKey → labels

    private func pick(idx: Int, question: AskWireQuestion, label: String) {
        guard status.isPending, !question.multiSelect else { return }
        picks[question.answerKey] = label
        // 单选即答（v3：点击即提交——所有题答完才算完；单题卡直接提交）。
        var all = picks
        for q in payload.questions where q.multiSelect {
            if let set = multiPicks[q.answerKey], !set.isEmpty {
                all[q.answerKey] = set.sorted().joined(separator: ", ")
            }
        }
        if allReady(all) {
            onSubmit(all)
        }
    }

    private func toggle(idx: Int, question: AskWireQuestion, label: String) {
        guard status.isPending, question.multiSelect else { return }
        var set = multiPicks[question.answerKey] ?? []
        if set.contains(label) { set.remove(label) } else { set.insert(label) }
        multiPicks[question.answerKey] = set
    }

    private func confirm(question: AskWireQuestion) {
        guard status.isPending else { return }
        var all = picks
        for q in payload.questions {
            if q.multiSelect, let set = multiPicks[q.answerKey], !set.isEmpty {
                all[q.answerKey] = set.sorted().joined(separator: ", ")
            }
        }
        if allReady(all) { onSubmit(all) }
    }

    /// 分页式：全部题有答案才允许提交（未答页继续翻）。
    private func allReady(_ answers: [String: String]) -> Bool {
        payload.questions.allSatisfy { answers[$0.answerKey]?.isEmpty == false }
    }
}

// MARK: - Page

private struct AskQuestionPage: View {
    let question: AskWireQuestion
    let index: Int
    let total: Int
    let status: AskCardStatus
    let palette: AskPalette
    let onPick: (String) -> Void
    let onToggle: (String) -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头行：？圆徽 + ASK + livedot + 序号
            HStack(spacing: 7) {
                AskMarkBadge(palette: palette, inactive: !status.isPending)
                Text("Ask")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(status.isPending ? palette.accentDeep : palette.expire)
                if status.isPending {
                    AskLiveDot(palette: palette)
                }
                Spacer(minLength: 8)
                Text(indexLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(palette.ink3)
            }

            Text(question.question)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            VStack(spacing: 7) {
                ForEach(question.options) { opt in
                    AskOptionRow(
                        option: opt,
                        multiSelect: question.multiSelect,
                        selected: isSelected(opt),
                        locked: !status.isPending,
                        dimmed: isDimmed(opt),
                        palette: palette
                    ) {
                        if question.multiSelect { onToggle(opt.label) } else { onPick(opt.label) }
                    }
                }
            }

            if question.multiSelect && status.isPending {
                AskConfirmCapsule(palette: palette) { onConfirm() }
            }
        }
        .padding(.horizontal, 2)
    }

    private var indexLabel: String {
        total > 1 ? "\(index + 1) / \(total)\(status.isPending ? "" : " · 已答")" : "—"
    }

    private var textColor: Color {
        status.isPending ? palette.ink : palette.ink2
    }

    private func isSelected(_ opt: AskWireQuestion.AskWireOption) -> Bool {
        if question.multiSelect {
            return (multiSetFromStatus)?.contains(opt.label) ?? false
        }
        return (pickedLabelFromStatus) == opt.label
    }

    /// 定格态从 answers 反推选中（回放/已答卡显示答案）；pending 态由父视图本地态驱动。
    private var pickedLabelFromStatus: String? {
        if case .answered(let answers) = status {
            return answers[question.answerKey]
        }
        return nil
    }

    private var multiSetFromStatus: Set<String>? {
        if case .answered(let answers) = status, let joined = answers[question.answerKey] {
            return Set(joined.components(separatedBy: ", "))
        }
        return nil
    }

    private func isDimmed(_ opt: AskWireQuestion.AskWireOption) -> Bool {
        // answered：选中的 55%，未选的 42%；skipped/expired 全体 42%。
        if case .answered = status { return !isSelected(opt) }
        if case .pending = status { return false }
        return true
    }
}

// MARK: - Row

private struct AskOptionRow: View {
    let option: AskWireQuestion.AskWireOption
    let multiSelect: Bool
    let selected: Bool
    let locked: Bool
    let dimmed: Bool
    let palette: AskPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                // 单选 radio / 多选圆角方块 checkbox（v3 设计）
                Group {
                    if multiSelect {
                        AskCheckbox(selected: selected, palette: palette)
                    } else {
                        AskRadio(selected: selected, palette: palette)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.ink3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(palette.fill)
            )
            .opacity(dimmed ? (selected ? 0.55 : 0.42) : 1)
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }
}

// MARK: - Controls

/// 单选 radio：17pt 圆环，选中橙色填充+白心弹入（spring 过冲 = v3 cubic-bezier）。
private struct AskRadio: View {
    let selected: Bool
    let palette: AskPalette

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? palette.accent : palette.radioBorder, lineWidth: 1.5)
            if selected {
                Circle()
                    .trim(from: 0.06, to: 0.94)
                    .fill(palette.accent)
                    .padding(2)
            }
        }
        .frame(width: 17, height: 17)
        .animation(.spring(response: 0.3, dampingRatio: 0.6), value: selected)
    }
}

/// 多选 checkbox：17pt 圆角方块（5pt 圆角），选中橙底白勾弹入。
private struct AskCheckbox: View {
    let selected: Bool
    let palette: AskPalette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? palette.accent : palette.radioBorder, lineWidth: 1.5)
            if selected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(palette.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 17, height: 17)
        .animation(.spring(response: 0.3, dampingRatio: 0.6), value: selected)
    }
}

/// multiSelect 确认胶囊（Claude 版视觉：全宽、armed 前 35% 灰）。
/// armed 状态由外部 computed 传入（选了东西就亮）。
private struct AskConfirmCapsule: View {
    let palette: AskPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("确认")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.ink)
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

/// 跳过按钮：页脚弱化灰胶囊（细描边）。设计语义：逃生门不是主操作。
private struct AskSkipButton: View {
    let palette: AskPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(palette.skipText)
                    .frame(width: 9, height: 1.5)
                Text("跳过")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(palette.skipText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .strokeBorder(palette.skipBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Header pieces

/// "？"圆徽：22pt，pending 橙调、终态灰调。
private struct AskMarkBadge: View {
    let palette: AskPalette
    let inactive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(inactive ? palette.expireTint : palette.accentTint)
            Text("?")
                .font(.custom("Georgia", size: 11.5).weight(.bold))
                .foregroundStyle(inactive ? palette.expire : palette.accentDeep)
        }
        .frame(width: 22, height: 22)
    }
}

/// livedot：橙 6pt 圆点 breath 2.4s 明暗呼吸（pp 定稿：简单圆点，替代扩散环）。
private struct AskLiveDot: View {
    let palette: AskPalette

    var body: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: 6, height: 6)
            .breathingDot
    }
}

/// 分段进度条（A 分页顶部）：绿已答 / 橙当前 / 灰未到。
private struct AskStepper: View {
    let count: Int
    let page: Int
    let statuses: [AskCardStatus]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(color(for: i))
                    .frame(height: 3.5)
            }
        }
    }

    private func color(for i: Int) -> Color {
        // 终态后按 status 着色；pending 期按翻页位置。
        let s = statuses.indices.contains(i) ? statuses[i] : .pending
        switch s {
        case .pending: return i == page ? .orange : Color(.systemGray4)
        case .answered: return AskPalette(scheme: .light).done
        case .skipped, .expired: return Color(.systemGray3)
        }
    }
}

// MARK: - Palette

/// v3 色板（Asset 化前先用语义 Color；深浅自适应——橙深色提亮 E08A64）。
struct AskPalette {
    let scheme: ColorScheme

    init(scheme: ColorScheme) { self.scheme = scheme }

    var card: Color { scheme == .dark ? Color(red: 0.138, green: 0.133, blue: 0.125) : .white }
    var cardBorder: Color { scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
    var ink: Color { scheme == .dark ? Color(red: 0.949, green: 0.945, blue: 0.929) : Color(red: 0.078, green: 0.078, blue: 0.075) }
    var ink2: Color { scheme == .dark ? Color(red: 0.722, green: 0.710, blue: 0.682) : Color(red: 0.333, green: 0.322, blue: 0.298) }
    var ink3: Color { scheme == .dark ? Color(red: 0.541, green: 0.529, blue: 0.498) : Color(red: 0.541, green: 0.529, blue: 0.498) }
    var hairline: Color { scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }
    var fill: Color { scheme == .dark ? Color(red: 0.173, green: 0.169, blue: 0.157) : Color(red: 0.961, green: 0.957, blue: 0.941) }
    var accent: Color { scheme == .dark ? Color(red: 0.878, green: 0.541, blue: 0.392) : Color(red: 0.851, green: 0.467, blue: 0.341) }
    var accentDeep: Color { scheme == .dark ? Color(red: 0.878, green: 0.541, blue: 0.392) : Color(red: 0.753, green: 0.369, blue: 0.235) }
    var accentTint: Color { scheme == .dark ? Color(red: 0.878, green: 0.541, blue: 0.392).opacity(0.10) : Color(red: 0.851, green: 0.467, blue: 0.341).opacity(0.08) }
    var done: Color { scheme == .dark ? Color(red: 0.357, green: 0.745, blue: 0.549) : Color(red: 0.243, green: 0.608, blue: 0.435) }
    var expire: Color { Color(red: 0.541, green: 0.529, blue: 0.498) }
    var expireTint: Color { scheme == .dark ? Color.white.opacity(0.07) : Color(red: 0.541, green: 0.529, blue: 0.498).opacity(0.10) }
    var radioBorder: Color { scheme == .dark ? Color(red: 0.290, green: 0.286, blue: 0.275) : Color(red: 0.784, green: 0.773, blue: 0.745) }
    var skipText: Color { Color(red: 0.541, green: 0.529, blue: 0.498) }
    var skipBorder: Color { scheme == .dark ? Color.white.opacity(0.14) : Color(red: 0.541, green: 0.529, blue: 0.498).opacity(0.28) }
    var onAccent: Color { scheme == .dark ? Color(red: 0.969, green: 0.969, blue: 0.957) : Color(red: 0.969, green: 0.969, blue: 0.961) }
}

// MARK: - breath modifier（livedot 专用）

private struct BreathingDot: ViewModifier {
    @State private var phase: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(phase == 0 ? 1 : 0.3)
            .scaleEffect(phase == 0 ? 1 : 0.78)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

extension View {
    var breathingDot: some View { modifier(BreathingDot()) }
}

#if DEBUG
#Preview("single") {
    AskQuestionCardView(
        payload: AskWirePayload(toolUseId: "t1", questions: [
            AskWireQuestion(question: "数据库迁移方案选哪个？", header: nil, multiSelect: false, options: [
                .init(label: "双写迁移", description: "新旧库同时写入，随时可回滚"),
                .init(label: "停机迁移", description: "维护窗口内一次性切换"),
                .init(label: "影子验证", description: "新库只读影子流量对账一周")
            ])
        ]),
        status: .pending,
        page: .constant(0),
        onSubmit: { _ in },
        onSkip: {}
    )
    .padding(16)
}

#Preview("multi") {
    AskQuestionCardView(
        payload: AskWirePayload(toolUseId: "t2", questions: [
            AskWireQuestion(question: "回归清单跑哪几项？", header: nil, multiSelect: true, options: [
                .init(label: "流式 e2e", description: nil),
                .init(label: "tsc 0 错", description: nil),
                .init(label: "preflight", description: nil)
            ])
        ]),
        status: .pending,
        page: .constant(0),
        onSubmit: { _ in },
        onSkip: {}
    )
    .padding(16)
    .preferredColorScheme(.dark)
}
#endif
