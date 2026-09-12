import XCTest
@testable import RemoteHistoryKit

/// [D1 2026-09-12] 回合间隙帧缓冲单测。
///
/// 背景：`permission_request` 在 `onMessage` handler 未安装的窗口内到达，
/// 被 nil no-op 静默吞掉 → AskUserQuestion 卡片从未建立（真机会话
/// E1AE859F 实证，客户端只收到 9 秒后的 AbortError 收尸帧）。
/// `OrphanFrameBuffer` 是该缺陷的纯逻辑修复核心：关键帧缓冲、安装时重放。
final class OrphanFrameBufferTests: XCTestCase {

    /// 最小消息桩：只保留判据所需的 type 字段。
    private struct StubMsg {
        let type: String?
    }

    /// 与 CCPocketClient 接线一致的判据：只缓冲 permission_request /
    /// tool_result 两类（重放副作用按 toolUseId 定位既有块，幂等安全）。
    private static func makeBuffer(limit: Int = 200) -> OrphanFrameBuffer<StubMsg> {
        OrphanFrameBuffer(limit: limit) { msg in
            switch msg.type ?? "" {
            case "permission_request", "tool_result": return true
            default: return false
            }
        }
    }

    // MARK: - 关键帧缓冲

    func test_buffer_keepsKeyFramesInArrivalOrder() {
        var buf = Self.makeBuffer()
        XCTAssertTrue(buf.buffer(StubMsg(type: "permission_request")))
        XCTAssertTrue(buf.buffer(StubMsg(type: "tool_result")))
        XCTAssertTrue(buf.buffer(StubMsg(type: "permission_request")))
        XCTAssertEqual(buf.frames.map(\.type), ["permission_request", "tool_result", "permission_request"],
                       "必须按到达序 FIFO 保存")
    }

    func test_buffer_dropsNonKeyFrames() {
        var buf = Self.makeBuffer()
        // 这些类型重放会污染新回合状态机（assistant→流式错位，
        // result→终结新回合），或已是幂等处理（input_ack 在 handleIncoming
        // 前段独立处理）—— 绝不入队。
        XCTAssertFalse(buf.buffer(StubMsg(type: "assistant")))
        XCTAssertFalse(buf.buffer(StubMsg(type: "result")))
        XCTAssertFalse(buf.buffer(StubMsg(type: "stream_delta")))
        XCTAssertFalse(buf.buffer(StubMsg(type: "input_ack")))
        XCTAssertFalse(buf.buffer(StubMsg(type: "status")))
        XCTAssertFalse(buf.buffer(StubMsg(type: nil)))
        XCTAssertTrue(buf.frames.isEmpty, "非关键帧必须全部被拒")
    }

    // MARK: - 重放语义

    func test_drain_returnsAllAndClears() {
        var buf = Self.makeBuffer()
        buf.buffer(StubMsg(type: "permission_request"))
        buf.buffer(StubMsg(type: "tool_result"))
        let drained = buf.drain()
        XCTAssertEqual(drained.map(\.type), ["permission_request", "tool_result"])
        XCTAssertTrue(buf.frames.isEmpty, "drain 后必须清空（防二次重放）")
        let again = buf.drain()
        XCTAssertTrue(again.isEmpty)
    }

    func test_buffer_limitDropsOldest() {
        var buf = Self.makeBuffer(limit: 3)
        buf.buffer(StubMsg(type: "permission_request")) // 最旧，将被挤出
        buf.buffer(StubMsg(type: "tool_result"))
        buf.buffer(StubMsg(type: "tool_result"))
        buf.buffer(StubMsg(type: "permission_request"))
        XCTAssertEqual(buf.frames.count, 3, "超限后必须维持 limit")
        XCTAssertEqual(buf.frames.map(\.type), ["tool_result", "tool_result", "permission_request"],
                       "挤出的是最旧一帧")
    }

    func test_removeAll_clearsEverything() {
        var buf = Self.makeBuffer()
        buf.buffer(StubMsg(type: "permission_request"))
        buf.buffer(StubMsg(type: "tool_result"))
        buf.removeAll()
        XCTAssertTrue(buf.frames.isEmpty, "disconnect 后旧连接帧绝不重放")
    }

    func test_buffer_limitFloorIsOne() {
        var buf = Self.makeBuffer(limit: 0) // 非法输入 → 收底为 1
        buf.buffer(StubMsg(type: "permission_request"))
        buf.buffer(StubMsg(type: "permission_request"))
        XCTAssertEqual(buf.frames.count, 1, "limit 最小为 1")
    }
}

/// [D3 2026-09-12] 显式停止标记单测（interruptIfExplicit 的判定核心）。
final class ExplicitStopFlagTests: XCTestCase {

    func test_consume_withoutMark_returnsFalse() {
        var flag = ExplicitStopFlag()
        XCTAssertFalse(flag.consume(), "生命周期类取消（未打标）必须被抑制")
        XCTAssertFalse(flag.isSet)
    }

    func test_consume_afterMark_returnsTrueOnce() {
        var flag = ExplicitStopFlag()
        flag.mark()
        XCTAssertTrue(flag.consume(), "显式停止后第一次消费必须放行 interrupt")
        XCTAssertFalse(flag.consume(), "一次性消费：第二次（下一次取消）必须复位")
    }

    func test_mark_isIdempotent() {
        var flag = ExplicitStopFlag()
        flag.mark()
        flag.mark()
        XCTAssertTrue(flag.consume())
        XCTAssertFalse(flag.consume())
    }
}
