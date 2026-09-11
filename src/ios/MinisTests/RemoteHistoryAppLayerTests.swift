import XCTest
@testable import Minis

/// [G-3 2026-09-12] app 层映射用例（依赖 CCPocketProtocol/RemoteAgentProvider/
/// AgentMessage——wire→engine 映射与 VM 类型，无法进纯 Foundation 的
/// RemoteHistoryKit 镜像包）。从包测试文件搬回，Xcode 本地跑；CI 真跑门
/// 覆盖的是包内纯逻辑（planReplace/identity/segment/replayId/cursor）。
final class RemoteHistoryAppLayerTests: XCTestCase {

    func test_pastHistoryRawDisk_convertedWithStableId() {
        // [C-5.5 会话窗连续] past_history 的磁盘 raw 消息（{role, content}，
        // 无 type）必须被解析且拿到稳定 past-{index} id——之前落 default
        // 全丢，resume/bridge 切换后窗口断裂。
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old reply"},{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"ls"}}]},
         {"role":"user","content":[{"type":"text","text":"old question"}]}]
        """
        let wire = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        let msgs = RemoteAgentProvider.historyAgentMessages(from: wire)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].dbMessageId, "past-0")
        XCTAssertEqual(msgs[0].rawMessageId(), "past-0", "rawMessageId 必须走 past- 分支")
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertNotNil(msgs[0].parts.first)
        XCTAssertEqual(msgs[1].dbMessageId, "past-1")
        XCTAssertEqual(msgs[1].role, .user)
        // tool_use 转 part
        if case .toolUse(let id, let name, _)? = msgs[0].parts.last {
            XCTAssertEqual(id, "t9")
            XCTAssertEqual(name, "Bash")
        } else {
            XCTFail("tool_use 块必须转成 .toolUse part")
        }
    }

    func test_productionIdStrategy_usesBridgeSeq() {
        var withSeq = AgentMessage(role: .assistant, parts: [])
        withSeq.bridgeSeq = 42
        XCTAssertEqual(withSeq.rawMessageId(), "bridge-42",
                       "bridgeSeq 必须派生为稳定的 bridge-{seq}，否则校准 keep 集永不命中")

        var noSeq = AgentMessage(role: .assistant, parts: [])
        XCTAssertNotEqual(noSeq.rawMessageId(), noSeq.rawMessageId(),
                          "无 bridgeSeq 必须每次新 UUID（live-stream 路径）")
    }

    func test_toolResultReplay_injectsBridgeSeq() {
        // agentMessage(fromServer:) 的 tool_result 分支必须注入 historySeq ——
        // 漏注入 = UUID id = 每次校准全量重插（v1.14.18 修复的根因 3）。
        let json = """
        {"type":"tool_result","toolUseId":"toolu-1","toolName":"Bash","content":"ok","historySeq":7,"sessionId":"s1"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.bridgeSeq, 7, "tool_result 回放必须携带 bridgeSeq")
        XCTAssertEqual(agent?.rawMessageId(), "bridge-7")
    }

    func test_wireContent_toolResultString_staysContent() {
        // [多态分流锁] tool_result 的 wire content 是字符串（工具输出）——
        // 手写 init 先试 String 再试 [AssistantContentBlock]，字符串形态
        // 必须落到 content 字段、rawContentBlocks 保持 nil。
        let json = """
        {"type":"tool_result","toolUseId":"t1","content":"stdout lines here","historySeq":4}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.content, "stdout lines here")
        XCTAssertNil(msg.rawContentBlocks, "字符串 content 不得被误读为块数组")
    }

    func test_wireContent_pastRawArray_landsBlocks() {
        // [多态分流锁] past_history 磁盘 raw 消息（{role, content:[blocks]}，
        // 无 type）——数组形态必须落到 rawContentBlocks、content 保持 nil，
        // role 走 rawRole。这是 C-5.5 会话窗连续的解码根基：分流错 = 磁盘
        // 历史整条丢弃（typeMismatch 炸包）或串进 tool_result 输出。
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old"},{"type":"thinking","thinking":"hm"}]}]
        """
        let msgs = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].rawRole, "assistant")
        XCTAssertNil(msgs[0].content, "数组 content 不得误落到字符串字段")
        XCTAssertEqual(msgs[0].rawContentBlocks?.count, 2)
        XCTAssertEqual(msgs[0].rawContentBlocks?.first?.text, "old")
        XCTAssertEqual(msgs[0].rawContentBlocks?.last?.thinking, "hm")
    }

    func test_wireContent_absent_bothNil() {
        // 无 content key 的消息（user_input / status / result）——两字段都 nil，
        // 不得互相污染（解码路径的 else 分支锁）。
        let json = """
        {"type":"user_input","text":"hi","historySeq":2}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.content)
        XCTAssertNil(msg.rawContentBlocks)
        XCTAssertEqual(msg.rawRole, nil)
    }

    // MARK: - messages 多态分流（v1.14.23 Phase 2：delta 信封解码）

    func test_wireMessages_flatShape_landsMessages() {
        // 全量 get_history 的信封 messages = flat [ServerMessage] → messages
        // 字段，deltaEntries 保持 nil（形状探测：首元素无 seq+message 包装）。
        let json = """
        {"type":"history","sessionId":"s1","messages":[{"type":"assistant","historySeq":1},{"type":"user_input","text":"hi","historySeq":2}]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.messages?.count, 2)
        XCTAssertNil(msg.deltaEntries, "flat 形态不得误判为 delta entries")
    }

    func test_wireMessages_deltaEntriesShape_landsDeltaEntries() {
        // [v1.14.23 关键坑位锁] delta 信封 messages = HistoryEntry[]——
        // 不能靠"flat 试错失败"分流（ServerMessage 全 optional 字段会把
        // entry 形态静默解成全 nil 空壳而非抛错），必须先探测 seq+message
        // 包装再分流。此用例锁该行为：deltaEntries 命中、messages nil。
        let json = """
        {"type":"history_delta","sessionId":"s1","fromSeq":11,"toSeq":12,
         "messages":[{"seq":11,"message":{"type":"assistant","text":"a","historySeq":11}},
                     {"seq":12,"message":{"type":"user_input","text":"b","historySeq":12}}]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.messages, "entry 形态不得误入 flat messages（会产出全 nil 空壳）")
        XCTAssertEqual(msg.deltaEntries?.count, 2)
        XCTAssertEqual(msg.deltaEntries?.first?.seq, 11)
        XCTAssertEqual(msg.deltaEntries?.first?.message?.historySeq, 11)
        XCTAssertEqual(msg.fromSeq, 11)
        XCTAssertEqual(msg.toSeq, 12)
    }

    func test_wireMessages_emptyDeltaShape() {
        // 空 delta（bridge getHistorySince:789）：from=to+1, messages=[]——
        // 空数组走 flat 分支（messages=[]），语义"无新消息"。
        let json = """
        {"type":"history_delta","sessionId":"s1","fromSeq":11,"toSeq":10,"messages":[]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.messages?.count, 0)
        XCTAssertNil(msg.deltaEntries)
        XCTAssertEqual(msg.fromSeq, 11)
        XCTAssertEqual(msg.toSeq, 10)
    }

    func test_wireMessages_missingShape_bothNil() {
        // 无 messages key（status / result 等信封）→ 双 nil 不互相污染。
        let json = """
        {"type":"status","sessionId":"s1","status":"idle"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.messages)
        XCTAssertNil(msg.deltaEntries)
    }

    func test_userInputReplay_converted() {
        // bridge 端 user turn 的 type 是 user_input（websocket.ts:3237）——
        // 旧代码落 default 分支整类丢弃（根因 3 之二）。
        let json = """
        {"type":"user_input","text":"hello world","historySeq":3,"sessionId":"s1"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent, "user_input 必须被转换，不得落入 default 丢弃")
        XCTAssertEqual(agent?.role, .user)
        XCTAssertEqual(agent?.bridgeSeq, 3)
        guard case .text(let t)? = agent?.parts.first else {
            return XCTFail("user_input 应转换为 .text part")
        }
        XCTAssertEqual(t, "hello world")
    }

    func test_assistantReplay_behaviorUnchanged() {
        // 防回归：assistant 转换的原有行为（blocks → parts + seq 注入）不变。
        let json = """
        {"type":"assistant","sessionId":"s1","historySeq":9,"message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a"}}]}}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.bridgeSeq, 9)
        XCTAssertEqual(agent?.parts.count, 2, "text + tool_use；thinking 进 reasoningContent")
        XCTAssertNotNil(agent?.reasoningContent)
    }

    // MARK: - [Fix 2026-09-11] disk past 内容完整性（tool_result/thinking）

    func test_pastToolResultRawShape_converted() {
        // bridge disk past 的 tool_result 重塑形态：splitPastHistoryMessages
        // 发 {role:"tool_result", toolUseId, content(string)}（无 type 字段，
        // websocket.ts:1909）——此前落 default 且 rawContentBlocks 为 nil
        // （content 是字符串）→ return nil 整行丢弃。实测 resume 后磁盘 623
        // 个工具结果 0 到达客户端（工具卡片点开无内容根因）。
        let json = """
        {"role":"tool_result","toolUseId":"toolu-9","content":"ran ok"}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertNotNil(agent, "disk past 的 tool_result 必须被转换，不得丢弃")
        XCTAssertEqual(agent?.role, .user)
        guard case .toolResult(let id, _, let content, let isError, _, _, _, _)? = agent?.parts.first else {
            return XCTFail("应转换为 .toolResult part")
        }
        XCTAssertEqual(id, "toolu-9")
        XCTAssertEqual(content, "ran ok")
        XCTAssertFalse(isError)
        // past-{index} 稳定 id（historyAgentMessages 统一分配）
        let engine = RemoteAgentProvider.historyAgentMessages(from: [msg])
        XCTAssertEqual(engine.count, 1)
        XCTAssertEqual(engine[0].dbMessageId, "past-0")
    }

    func test_pastRawThinking_converted() {
        // disk past 的 assistant 条目带 thinking 块（bridge 补全解析后）——
        // rawContentBlocks 路径必须提 reasoningContent，否则 resume 后
        // 思考块丢失（另一半根因）。
        let json = """
        {"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}
        """
        let msg = try! JSONDecoder().decode(CCPocketProtocol.ServerMessage.self, from: Data(json.utf8))
        let agent = RemoteAgentProvider.agentMessage(fromServer: msg)
        XCTAssertEqual(agent?.reasoningContent, "hmm")
        XCTAssertEqual(agent?.parts.count, 1)
    }

    func test_rawMessageId_usesNamespaceAndSegment() {
        var msg = AgentMessage(role: .assistant, parts: [.text("x")])
        msg.bridgeSeq = 42
        msg.replayIdNamespace = "abc12345"
        msg.replayIdSegment = "43db1176"
        XCTAssertEqual(msg.rawMessageId(), "bridge-abc12345-43db1176-42")
    }

    func test_rawMessageId_legacyFallbackWithoutNamespace() {
        var msg = AgentMessage(role: .assistant, parts: [.text("x")])
        msg.bridgeSeq = 42
        XCTAssertEqual(msg.rawMessageId(), "bridge-42",
                       "无 ns 时保持旧形态（兜底路径），旧数据语义不变")
    }

    func test_historyAgentMessages_injectsNamespaceSegmentAndClientId() {
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old reply"}]},
         {"type":"user_input","text":"hi","clientMessageId":"cmid-1","historySeq":7,"sessionId":"s1"}]
        """
        let wire = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        let msgs = RemoteAgentProvider.historyAgentMessages(
            from: wire, namespace: "abc12345", segment: "43db1176", diskSegment: "9f3e2a1b"
        )
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].dbMessageId, "past-abc12345-9f3e2a1b-0",
                       "past 行 id 必须带 disk 段（跨设备 transcript 不同，index 都从 0 起）")
        XCTAssertEqual(msgs[0].rawMessageId(), "past-abc12345-9f3e2a1b-0")
        XCTAssertNil(msgs[0].clientMessageId, "磁盘 past 行没有协议身份（只有 bridge 历史条目有）")
        XCTAssertEqual(msgs[1].rawMessageId(), "bridge-abc12345-43db1176-7")
        XCTAssertEqual(msgs[1].clientMessageId, "cmid-1",
                       "协议身份必须从 wire 带到 AgentMessage——校准期对账靠它")
    }

    func test_historyAgentMessages_degradesWithoutDiskSegment() {
        let json = """
        [{"role":"assistant","content":[{"type":"text","text":"old reply"}]}]
        """
        let wire = try! JSONDecoder().decode([CCPocketProtocol.ServerMessage].self, from: Data(json.utf8))
        let msgs = RemoteAgentProvider.historyAgentMessages(
            from: wire, namespace: "abc12345", segment: "43db1176", diskSegment: nil
        )
        XCTAssertEqual(msgs[0].dbMessageId, "past-abc12345-0",
                       "磁盘段缺失时退回 v1.14.29 形态（兜底链，不崩）")
    }
}