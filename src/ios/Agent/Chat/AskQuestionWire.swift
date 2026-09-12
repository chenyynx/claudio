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
        // 没有任何可选项的题无法作答 → 判为畸形题（整帧降级为工具卡），
        // 不渲染一张只有题面、永远答不了的死卡。
        if options.isEmpty { return nil }
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
        // 只认官方 schema（`questions` 数组）。曾有的「扁平单问」容错已删除：
        // 桥 buildAskUserAnswers 只读 input.questions，扁平形态下它解析不出题
        // （`answer() could not resolve AskUserQuestion text`）→ 卡片能答但答案
        // 被静默丢弃。契约不成立的形状一律不渲染（整帧降级为普通工具卡）。
        guard let arr = input["questions"] as? [[String: Any]], !arr.isEmpty else { return nil }
        let parsed = arr.compactMap { AskWireQuestion(dict: $0) }
        // 全有或全无：丢题会让 envelope 的题目序列与桥侧原始 input 错位，
        // 桥按「长度+顺序一致」校验，错位即整包答案被丢弃（比不答更糟）。
        guard parsed.count == arr.count else { return nil }
        let questions = parsed
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
///
/// 格式与桥 `buildAskUserAnswers`（sdk-process.ts:273）严格互逆，且与官方
/// Flutter `ask_user_question_widget.dart:_sendAllAnswers` 一致：
/// - **单题单选** → 纯答案文本（桥的非 JSON 兜底分支 `rawQuestionTexts.length===1`）
/// - **其余形态（多题 / multiSelect）** → envelope JSON
///   `{"questions":[…], "answers":{问题文本: 答案}}`。桥要求 envelope 里的
///   questions 文本序列与原 input **长度+顺序完全一致**，否则整包丢弃
///   （`Ignoring non-envelope answer for multiple questions`）；multiSelect
///   回字符串数组（桥侧 join(", ")）。
enum AskResultCodec {
    static func result(for questions: [AskWireQuestion], answers: [String: String]) -> String {
        guard !answers.isEmpty else { return "" }
        if questions.count == 1, !questions[0].multiSelect {
            return answers[questions[0].answerKey] ?? ""
        }
        let payload: [String: Any] = [
            "questions": questions.map { $0.asDict },
            "answers": answersEnvelope(for: questions, answers: answers),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            // 序列化失败兜底：单题退化成纯文本，多题无解（宁可少答不可错答）。
            return questions.first.map { answers[$0.answerKey] ?? "" } ?? ""
        }
        return json
    }

    /// answers 以**问题文本**为 key（桥按 questionTexts 查表）；multiSelect
    /// 拆成数组。未答的题不进 envelope（桥侧对 undefined 只告警不写入）。
    private static func answersEnvelope(
        for questions: [AskWireQuestion],
        answers: [String: String]
    ) -> [String: Any] {
        var out: [String: Any] = [:]
        for q in questions {
            guard let a = answers[q.answerKey], !a.isEmpty else { continue }
            out[q.answerKey] = q.multiSelect ? a.components(separatedBy: ", ") : a
        }
        return out
    }
}
