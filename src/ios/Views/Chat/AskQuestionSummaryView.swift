//
//  AskQuestionSummaryView.swift
//  问题卡终态 —— 照 Happy 的 submittedContainer：逐题「header：答案」两列行。
//
//  与卡片的分工：pending 渲染 AskQuestionCardView（可交互），终态渲染本视图
//  （只读记录，占位从 ~320pt 收到 ~90pt，聊天流不涨）。
//  皮肤同族：复用共享 glassSurface 材质，不叠第二套卡片语言。
//
//  [不照抄 Happy 的一处] 它的 selectedLabels 只从组件内 selections 取，
//  而进入条件是 isSubmitted || tool.state==='completed' —— 重连/回放时
//  selections 为空、答案栏渲染成空白。我们这里答案一律由调用方从
//  block.askStatus（Store 侧）传入，视图不自己猜。
//

import SwiftUI

struct AskQuestionSummaryView: View {
    let payload: AskWirePayload
    let status: AskCardStatus

    @Environment(\.colorScheme) private var scheme
    private var palette: AskPalette { .init(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(palette.ink3)
            ForEach(payload.questions) { question in
                answerRow(question)
            }
            Divider()
                .overlay(palette.hairline)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Image(systemName: footnoteIcon)
                    .font(.system(size: 11, weight: .semibold))
                Text(footnote)
                    .font(.system(size: 11))
            }
            .foregroundStyle(footnoteColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassSurface(radius: 28, dark: scheme == .dark)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.09), radius: 18, x: 0, y: 7)
    }

    // MARK: - 片段

    private var headline: String {
        switch status {
        case .pending: "待回答"
        case .answered: "已回答"
        case .expired: "回合已结束 · 未回答"
        }
    }

    @ViewBuilder
    private func answerRow(_ question: AskWireQuestion) -> some View {
        let answer = answerText(for: question)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(question.header.flatMap { $0.isEmpty ? nil : $0 } ?? question.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink3)
                .lineLimit(1)
            Text(answer)
                .font(.system(size: 13))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func answerText(for question: AskWireQuestion) -> String {
        guard case .answered(let answers) = status,
              let value = answers[question.answerKey], !value.isEmpty else {
            return "—"
        }
        return value
    }

    private var footnoteIcon: String {
        switch status {
        case .answered: "checkmark"
        default: "circle"
        }
    }

    private var footnote: String {
        switch status {
        case .pending: "等待选择"
        case .answered: "答案已回传 · Claude 继续执行"
        case .expired: "未回答 · 该问题已失效"
        }
    }

    private var footnoteColor: Color {
        // batch1.7 定稿「纯墨」：终态不引入彩色（AskPalette.done 绿已随选中态一起删）。
        // 已答用 ink2 比 ink3 略重一档，靠明度而不是色相区分状态。
        if case .answered = status { return palette.ink2 }
        return palette.ink3
    }
}

#if DEBUG
#Preview("终态") {
    let payload = AskWirePayload(toolUseId: "tu_s", questions: [
        AskWireQuestion(question: "数据库迁移走哪条路？", header: "方案", multiSelect: false,
                        options: [.init(label: "双写迁移", description: nil)]),
        AskWireQuestion(question: "这次跑哪些回归？", header: "验证", multiSelect: true,
                        options: [.init(label: "e2e", description: nil), .init(label: "tsc", description: nil)]),
    ])
    return VStack(spacing: 14) {
        AskQuestionSummaryView(payload: payload, status: .answered(answers: [
            "数据库迁移走哪条路？": "双写迁移",
            "这次跑哪些回归？": "e2e, tsc",
        ]))
        AskQuestionSummaryView(payload: payload, status: .expired)
    }
    .padding(16)
    .background(Color(.systemGroupedBackground))
}
#endif
