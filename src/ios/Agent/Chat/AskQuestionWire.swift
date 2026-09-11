//
//  AskQuestionWire.swift
//  AskUserQuestion wire 模型 — Bridge permission_request 帧载荷（toolName ==
//  "AskUserQuestion"）的结构化解码。设计基准 ask-user-question-card-v3.html
//  （跳过/ASK 标签/breath 圆点/multiSelect checkbox/A 分页/折叠摘要）。
//
//  [隔离架构铁律] 本文件只服务远端 AskUserQuestion 流内卡片；本地 agent 从
//  不产生 AskUserQuestion 工具。所有类型纯 Foundation，不依赖 VM。
//

import Foundation

// MARK: - Wire payload

/// Bridge `permission_request.input.questions` — official AskUserQuestion
/// schema: `{questions: [{question, options: [{label, description}], multiSelect?}]}`
/// （per-question multiSelect；header 可选字段亦容忍）。
struct AskWireQuestion: Identifiable, Equatable {
    let id: String            // question text（桥 buildAskUserAnswers 以问题文本为 key）
    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [AskWireOption]

    struct AskWireOption: Identifiable, Equatable {
        let id: String        // label
        let label: String
        let description: String?

        init(id: String = UUID().uuidString, label: String, description: String?) {
            self.id = id
            self.label = label
            self.description = description
        }

        init?(dict: [String: Any]) {
            guard let label = dict["label"] as? String, !label.isEmpty else { return nil }
            self.id = label
            self.label = label
            self.description = dict["description"] as? String
        }

        var asDict: [String: Any] {
            var d: [String: Any] = ["label": label]
            if let description { d["description"] = description }
            return d
        }
    }

    init(id: String = UUID().uuidString, question: String, header: String?, multiSelect: Bool, options: [AskWireOption]) {
        self.id = id
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    init?(dict: [String: Any]) {
        guard let question = dict["question"] as? String, !question.isEmpty else { return nil }
        self.id = question
        self.question = question
        self.header = dict["header"] as? String
        // per-question multiSelect（official schema）；整卡级兜底。
        self.multiSelect = (dict["multiSelect"] as? Bool) ?? false
        let rawOptions = (dict["options"] as? [[String: Any]]) ?? []
        self.options = rawOptions.compactMap { AskWireOption(dict: $0) }
    }

    var asDict: [String: Any] {
        var d: [String: Any] = ["question": question]
        if let header { d["header"] = header }
        if multiSelect { d["multiSelect"] = true }
        d["options"] = options.map { $0.asDict }
        return d
    }

    /// 唯一 answer key：官方 buildAskUserAnswers 按问题文本映射答案。
    var answerKey: String { question }
}

/// 一次 AskUserQuestion permission_request 的完整载荷（toolUseId + questions）。
/// `questions` 为空数组 = 帧形状异常（造卡层按 expired 处理，不弹窗）。
struct AskWirePayload: Equatable {
    let toolUseId: String
    let questions: [AskWireQuestion]

    /// 从 provider 的 `input`（JSON 载荷）解码。容忍官方 schema 与扁平
    /// 单问形态（`question` 顶层字符串）。返回 nil = 无法理解的问题载荷。
    static func decode(toolUseId: String, input: [String: Any]) -> AskWirePayload? {
        let questions: [AskWireQuestion]
        if let arr = input["questions"] as? [[String: Any]] {
            questions = arr.compactMap { AskWireQuestion(dict: $0) }
        } else if let flat = input["question"] as? String, !flat.isEmpty,
                  let options = (input["options"] as? [[String: Any]])?.compactMap({ AskWireQuestion.AskWireOption(dict: $0) }),
                  !options.isEmpty {
            questions = [AskWireQuestion(question: flat, header: input["header"] as? String, multiSelect: (input["multiSelect"] as? Bool) ?? false, options: options)]
        } else {
            return nil
        }
        guard !questions.isEmpty else { return nil }
        return AskWirePayload(toolUseId: toolUseId, questions: questions)
    }

    var asDict: [String: Any] {
        ["questions": questions.map { $0.asDict }]
    }

    /// 单选（所有题都单选且只有一题）→ 选中即答；否则需要确认键。
    var isSingleTap: Bool {
        questions.count == 1 && !questions[0].multiSelect
    }
}

// MARK: - Card state

/// 流内问题卡的生命周期四态（v3 设计：pending / answered / skipped / expired）。
enum AskCardStatus: Equatable {
    case pending
    /// 答案已回传（answers 按题的 answerKey 索引；multiSelect 为 join 后字符串）。
    case answered(answers: [String: String])
    /// 用户点了跳过（cancel 回合，模型收到"未回答"）。
    case skipped
    /// 回合收场（STALL/超时/断连）时仍未答——置灰定格。
    case expired
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// 答案 → 桥 `answer(toolUseId, result)` 的 result 字符串。
/// 单题：直接答案文本。多题：官方按 `questionText` join（messages.dart 先例）。
enum AskResultCodec {
    /// 多答案合并：与桥侧 buildAskUserAnswers 的 `question text` 键语义一致——
    /// 单题回 label/自定义文本；多题回 JSON-ish join（`q1: a1; q2: a2`）。
    /// 桥实际以 question text 为 key 查 answers，多题时 result 需要携带可解析结构。
    static func result(for questions: [AskWireQuestion], answers: [String: String]) -> String {
        guard !answers.isEmpty else { return "" }
        // 每题的答案取 answerKey 命中的值；多题序列化成单字符串。
        let parts: [String] = questions.compactMap { q in
            guard let a = answers[q.answerKey], !a.isEmpty else { return nil }
            return questions.count > 1 ? "\(q.answerKey): \(a)" : a
        }
        return parts.joined(separator: "; ")
    }
}
