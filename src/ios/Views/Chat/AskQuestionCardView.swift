//
//  AskQuestionCardView.swift
//  流内 AskUserQuestion 问题卡 —— 逻辑照 Happy，皮肤用我们既有的液态玻璃。
//
//  逻辑（Happy InlineQuestionForm 逐行核对后照搬，源码在 slopus/happy
//  packages/happy-app/sources/components/tools/views/）：
//   · 只有 1 种形态：多题一律纵向堆叠在同一张卡里，不分页
//   · 提交键常驻：单选/多选都靠它提交，全部题都选了才 enabled
//     （Happy 的 handleOptionToggle 只改 state，不提交；handleSubmit 绑提交键）
//   · 单选=替换、多选=toggle，按每题 multiSelect 决定
//   · header 短标签 + question 文本 + option.description 第二行（有则显示）
//  皮肤（复用共享组件 glassSurface，不自己造材质）：
//   · 液态玻璃 + 28pt 连续圆角 + black 6% 描边 + 0.10/20/8 投影（= Claude 版几何）
//   · 选中态纯墨：文字加粗 + 右侧 ✓，不用色块、不用橙（橙只出现在 livedot）
//   · 选项之间 hairline 分隔（pp 定「就线吧」，不叠灰块）
//   · livedot：6pt 橙点 breath 2.4s 明暗呼吸 = pending 活性信号
//
//  [状态外提] 草稿选中存在 AssistantBlock.askDraft（Store 侧），不放 @State ——
//  聊天列表是 UICollectionView cell 复用，视图内 @State 会被清零（勾会莫名丢失）。
//
//  [隔离] 纯展示组件，只被 questionCard 块渲染；本地 agent 无此块类型。
//

import SwiftUI

struct AskQuestionCardView: View {
    let payload: AskWirePayload
    let status: AskCardStatus
    /// 草稿选中存这儿（cell 复用安全），视图只读写这一个字段。
    @ObservedObject var block: AssistantBlock
    let onSubmit: ([String: String]) -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: AskPalette { .init(scheme: scheme) }

    private var isLive: Bool { status.isPending }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            metaLine
            ForEach(payload.questions) { question in
                questionSection(question)
            }
            submitBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .glassSurface(radius: 28, dark: scheme == .dark)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.10), radius: 20, x: 0, y: 8)
    }

    // MARK: - 片段

    /// 活性行：呼吸橙点 + 状态提示（无 ASK 标签、无「？」徽 —— 标题自己就是身份）
    private var metaLine: some View {
        HStack(spacing: 7) {
            if isLive { AskLiveDot(palette: palette) }
            Text(isLive ? "回合已暂停 · 选完提交" : "已回答")
                .font(.system(size: 11))
                .foregroundStyle(palette.ink3)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func questionSection(_ question: AskWireQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(palette.ink2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(palette.chip)
                    )
            }
            Text(question.question)
                .font(.system(size: 15, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(question.options.enumerated()), id: \.element.id) { idx, option in
                AskOptionRow(
                    option: option,
                    selected: isSelected(option, in: question),
                    enabled: isLive,
                    showTopLine: idx > 0,
                    palette: palette
                ) {
                    toggle(option, in: question)
                }
            }
        }
    }

    /// 提交键常驻（Happy 同款：右对齐窄版，不是全宽胶囊）。
    private var submitBar: some View {
        HStack {
            Spacer()
            Button {
                guard allAnswered else { return }
                onSubmit(collectedAnswers)
            } label: {
                Text("提交答案")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onInk)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(palette.ink)
                    )
            }
            .buttonStyle(.plain)
            .opacity(allAnswered ? 1 : 0.42)
            .disabled(!allAnswered || !isLive)
            .animation(.easeInOut(duration: 0.2), value: allAnswered)
        }
    }

    // MARK: - 选中态（读写 block.askDraft）

    private func isSelected(_ option: AskWireQuestion.AskWireOption, in question: AskWireQuestion) -> Bool {
        block.askDraft[question.answerKey]?.contains(option.label) ?? false
    }

    private func toggle(_ option: AskWireQuestion.AskWireOption, in question: AskWireQuestion) {
        guard isLive else { return }
        var draft = block.askDraft
        if question.multiSelect {
            var set = draft[question.answerKey] ?? []
            if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
            draft[question.answerKey] = set
        } else {
            draft[question.answerKey] = [option.label]   // 单选=替换，但仍需按提交键
        }
        block.askDraft = draft
    }

    private var collectedAnswers: [String: String] {
        // 转换逻辑已上提到 AskWirePayload.answers(fromDraft:)：卡片提交与
        // batch1.8 输入即答共用一处实现。
        payload.answers(fromDraft: block.askDraft)
    }

    private var allAnswered: Bool {
        payload.questions.allSatisfy { (block.askDraft[$0.answerKey]?.isEmpty == false) }
    }
}

// MARK: - 选项行（纯文字 + hairline + 右侧 ✓）

private struct AskOptionRow: View {
    let option: AskWireQuestion.AskWireOption
    let selected: Bool
    let enabled: Bool
    let showTopLine: Bool
    let palette: AskPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                if showTopLine {
                    palette.hairline
                        .frame(height: 1)
                        .padding(.bottom, 9)
                }
                HStack(alignment: .top, spacing: 11) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.label)
                            .font(.system(size: 14, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? palette.ink : palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                        if let desc = option.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 12.5))
                                .lineSpacing(2)
                                .foregroundStyle(palette.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(width: 18)
                        .opacity(selected ? 1 : 0)
                }
                .padding(.vertical, 11)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 活性圆点

/// 橙 6pt 呼吸点（pp 定稿：简单圆点，不做扩散环）。
struct AskLiveDot: View {
    let palette: AskPalette
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.3 : 1)
            .scaleEffect(dimmed ? 0.78 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

// MARK: - 色板（选中态不含橙）

struct AskPalette {
    let scheme: ColorScheme

    init(scheme: ColorScheme) { self.scheme = scheme }

    private var dark: Bool { scheme == .dark }

    var cardBorder: Color { dark ? .white.opacity(0.09) : .black.opacity(0.06) }
    var hairline: Color { dark ? .white.opacity(0.09) : .black.opacity(0.085) }
    var ink: Color { dark ? Color(red: 0.949, green: 0.945, blue: 0.929) : Color(red: 0.078, green: 0.078, blue: 0.075) }
    /// 未选中文字：降半级灰度拉开层次（不靠色块）
    var inkSoft: Color { dark ? Color(red: 0.824, green: 0.820, blue: 0.804) : Color(red: 0.235, green: 0.231, blue: 0.220) }
    var ink2: Color { dark ? Color(red: 0.722, green: 0.710, blue: 0.682) : Color(red: 0.333, green: 0.322, blue: 0.298) }
    var ink3: Color { Color(red: 0.541, green: 0.529, blue: 0.498) }
    var chip: Color { dark ? .white.opacity(0.10) : .black.opacity(0.07) }
    var onInk: Color { dark ? Color(red: 0.086, green: 0.082, blue: 0.078) : Color(red: 0.969, green: 0.969, blue: 0.961) }
    /// 仅 livedot 用
    var accent: Color { dark ? Color(red: 0.878, green: 0.541, blue: 0.392) : Color(red: 0.851, green: 0.467, blue: 0.341) }
}

#if DEBUG
#Preview("问题卡 · 玻璃 + 纯线") {
    let block = AssistantBlock(kind: .questionCard, content: "", toolStatus: .running, toolUseId: "tu_p")
    block.askPayload = AskWirePayload(toolUseId: "tu_p", questions: [
        AskWireQuestion(
            question: "数据库迁移走哪条路？",
            header: "方案",
            multiSelect: false,
            options: [
                .init(label: "双写迁移", description: "新旧库同时写入，随时可回滚"),
                .init(label: "停机迁移", description: "维护窗口内一次性切换"),
            ]
        ),
        AskWireQuestion(
            question: "这次跑哪些回归检查？",
            header: "验证",
            multiSelect: true,
            options: [
                .init(label: "e2e + tsc strict", description: "常规两项"),
                .init(label: "再加对抗契约", description: "编码改动后必须跑"),
            ]
        ),
    ])
    return ScrollView {
        VStack(spacing: 16) {
            AskQuestionCardView(payload: block.askPayload!, status: .pending, block: block, onSubmit: { _ in })
        }
        .padding(16)
    }
    .background(Color(.systemGroupedBackground))
}
#endif
