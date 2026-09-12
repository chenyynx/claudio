import Foundation

/// [D1 2026-09-12] 回合间隙帧缓冲。
///
/// 真机实证（会话 E1AE859F，21:33:08）：桥发的 `permission_request` 在
/// `onMessage` handler 未安装的窗口内到达，被 `onMessage?(message)` 的
/// nil no-op 静默吞掉 → AskUserQuestion 卡片从未建立（客户端只收到 9 秒后
/// 的 AbortError 收尸帧），用户被迫重发第二次。
///
/// 本缓冲把「回合级关键帧」暂存，handler 安装时按到达序重放。
///
/// **缓冲集合刻意收窄到 `permission_request` / `tool_result`**（由调用方
/// `shouldBuffer` 判据决定），原因：
///  - `assistant` / `stream_delta` 重放会污染新回合的流式状态机
///    （`openTextBlockIfNeeded` 会把旧正文追加到新消息上）；
///  - `result` / `error` 是回合终局帧，重放会立即终结新回合；
///  - 这两类的重放副作用是「按 toolUseId 定位既有块」（attachAskCard /
///    toolResult 的 blockIdx 匹配），找不到即丢弃，天然幂等安全。
///
/// 泛型 + 闭包判据：纯 Foundation 零依赖，供 RemoteHistoryKit 单测
/// （与该包 "test-only 镜像、symlink 回 app 源文件" 模式一致）。
struct OrphanFrameBuffer<T> {
    /// 缓冲上限：防 handler 长期不装导致内存无限增长。最小 1。
    let limit: Int
    /// 判据：true = 该帧必须缓冲（回合级关键帧）。
    let shouldBuffer: (T) -> Bool

    private(set) var frames: [T] = []

    init(limit: Int = 200, shouldBuffer: @escaping (T) -> Bool) {
        self.limit = max(1, limit)
        self.shouldBuffer = shouldBuffer
    }

    /// handler 未安装时调用：关键帧入队（FIFO，超限丢最旧）。
    /// 返回是否入队（非关键帧返回 false，调用方可据此降级记日志）。
    mutating func buffer(_ frame: T) -> Bool {
        guard shouldBuffer(frame) else { return false }
        frames.append(frame)
        if frames.count > limit {
            frames.removeFirst(frames.count - limit)
        }
        return true
    }

    /// handler 安装时调用：取走全部缓冲帧（按到达序），并清空。
    /// 调用方必须**先装 handler 再 drain**——重放期间新到的帧会直接
    /// 进入新 handler，不会被二次缓冲。
    mutating func drain() -> [T] {
        let out = frames
        frames = []
        return out
    }

    /// 显式清空（deliberate disconnect / 换会话时调用——
    /// 旧连接 epoch 的帧绝不重放）。
    mutating func removeAll() {
        frames = []
    }
}

/// [D3 2026-09-12] 显式停止标记（一次性消费）。
///
/// `CCPocketClient.interruptIfExplicit` 的判定核心：只有用户主动点停止
/// （`AIChatViewModel.cancel()` → `markExplicitStop()`）才允许向桥发
/// interrupt；生命周期类 Task 取消（视图重挂载 / 后台）不置位 → 抑制。
/// 纯 Foundation 逻辑，进 RemoteHistoryKit 单测。
///
/// 线程安全：内部自旋在调用方持有的锁之外不共享状态——类型本身非
/// Sendable，`CCPocketClient` 用 NSLock 串行化对它的访问（与 orphanBuffer
/// 同一把锁族）。
struct ExplicitStopFlag {
    private(set) var isSet = false

    /// 标记下一次取消为用户显式停止。幂等。
    mutating func mark() { isSet = true }

    /// 取走标记（消费后自动复位）。返回 true = 本次取消来自显式停止。
    mutating func consume() -> Bool {
        let v = isSet
        isSet = false
        return v
    }
}
