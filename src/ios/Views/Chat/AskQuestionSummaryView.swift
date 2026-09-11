//
//  AskQuestionSummaryView.swift
//  折叠摘要（v3 设计：答完塌缩成摘要卡——Claude 版 AnsweredSummaryView
//  胶囊链的皮肤化实现）。answered / skipped 卡 + 历史（answered / skipped /
//  expired）回放共用。
//
//  与 AskQuestionCardView 分工：pending 期渲染完整卡；终态后渲染本摘要
//  （历史保持短——v3 ⑤ 的设计）。数据自足（payload + status），无回调。
//

import SwiftUI

struct AskQuestionSummaryView: View {
    let payload: AskWirePayload
    let status: AskCardStatus

    @Environment(\.colorScheme) private var scheme
    private var palette: AskPalette { .init(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(payload.questions.enumerated()), id: \.element.id) { _, q in
                VStack(alignment: .leading, spacing: 5) {
                    Text(q.question)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    chips(question: q)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private func chips(question: AskWireQuestion) -> some View {
        switch status {
        case .answered(let answers):
            if let joined = answers[question.answerKey], !joined.isEmpty {
                HStack(spacing: 6) {
                    ForEach(joined.components(separatedBy: ", "), id: \.self) { label in
                        AskChip(text: label, palette: palette, style: .done)
                    }
                }
            } else {
                AskChip(text: "未回答", palette: palette, style: .skipped)
            }
        case .skipped:
            AskChip(text: "已跳过 · 未回答", palette: palette, style: .skipped)
        case .expired:
            AskChip(text: "回合已结束 · 未回答", palette: palette, style: .skipped)
        case .pending:
            // pending 不会渲染摘要（父层 gate）；防御分支。
            AskChip(text: "…", palette: palette, style: .skipped)
        }
    }
}

/// 答案胶囊：绿=已答（done）、灰=跳过/未答（中性非状态色——跳过不是错误）。
struct AskChip: View {
    let text: String
    let palette: AskPalette
    let style: Style

    enum Style { case done, skipped }

    var body: some View {
        HStack(spacing: 4) {
            if style == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 12.5, weight: style == .done ? .semibold : .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(bg))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
    }

    private var fg: Color { style == .done ? palette.done : palette.skipText }
    private var bg: Color {
        style == .done
            ? palette.done.opacity(scheme2 == .dark ? 0.12 : 0.08)
            : (scheme2 == .dark ? Color.white.opacity(0.06) : Color(red: 0.541, green: 0.529, blue: 0.498).opacity(0.09))
    }
    private var border: Color {
        style == .done
            ? palette.done.opacity(scheme2 == .dark ? 0.18 : 0.20)
            : (scheme2 == .dark ? Color.white.opacity(0.10) : Color(red: 0.541, green: 0.529, blue: 0.498).opacity(0.20))
    }
    @Environment(\.colorScheme) private var scheme2
}

#if DEBUG
#Preview("answered") {
    VStack(spacing: 12) {
        AskQuestionSummaryView(
            payload: AskWirePayload(toolUseId: "t1", questions: [
                AskWireQuestion(question: "发版渠道走 main？", header: nil, multiSelect: false, options: [.init(label: "是", description: nil), .init(label: "开分支", description: nil)]),
                AskWireQuestion(question: "重启窗口现在可以吗？", header: nil, multiSelect: false, options: [.init(label: "现在可以", description: nil), .init(label: "等 10 分钟", description: nil)])
            ]),
            status: .answered(answers: ["发版渠道走 main？": "是", "重启窗口现在可以吗？": "现在可以"])
        )
        AskQuestionSummaryView(
            payload: AskWirePayload(toolUseId: "t2", questions: [
                AskWireQuestion(question: "顺手升级依赖吗？", header: nil, multiSelect: false, options: [.init(label: "升", description: nil), .init(label: "先不动", description: nil)])
            ]),
            status: .skipped
        )
    }
    .padding(16)
    .background(Color(.systemGroupedBackground))
}
#endif
