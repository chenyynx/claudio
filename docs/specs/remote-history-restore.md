# A 方案 Spec：远端 agent 恢复权威源切换 — bridge history 回填

> 2026-09-01 Doris 起草（pp 拍板「A 方案提级 M2 前」）。
> 背景：99e2828 快照方案上线首日即现「杀后台重进丢正文」（a9c67f4 止血）。
> 根因是结构性的：本地 uiSequence 快照成为远端恢复的第二事实源，与 bridge 真源必然漂移。
> 本方案 = 远端恢复回到官方语义（C-0）：**bridge 是唯一真相**，本地 DB 降级为缓存。
> 完成后远端恢复层与本地快照彻底解耦，同类 bug 在远端免疫。

## 1. 官方语义（源码实锤，均为 ~/refs/ccpocket-main/apps/mobile/lib）

| 机制 | 官方做法 | 源码位置 |
|------|---------|---------|
| 请求全量 | `{'type':'get_history','sessionId':X}` | models/messages.dart:4648 |
| 请求增量 | `{'type':'get_history_delta','sessionId':X,'sinceSeq':N}`（有本地缓存时优先发增量） | models/messages.dart:4652；bridge_service.dart:2840-2845 |
| 降级 | delta 返回 `unsupported_message` 时 fallback 全量 get_history | bridge_service.dart:871-878, 1450 |
| 响应模型 | `HistoryDeltaMessage/HistorySnapshotMessage`：sessionId + fromSeq/toSeq + entries[{seq,message}] + status(+reason) | models/messages.dart:1854-1880 |
| 累积 | `_runtimeStore.applyServerMessage` 按 sessionId 维护 timeline（cachedHistorySeq/latestSeq 推进） | bridge_service.dart:1392-1398 |
| 发给 UI | 累积结果包成 `HistoryMessage(messages:[ServerMessage])` 投给 controller | bridge_service.dart:1400-1423 |
| 渲染 | **历史与实时走同一条管道**：cubit `_handleMessage → _applyUpdate`，无「恢复专用渲染路径」 | chat_session_cubit.dart:289-316 |
| 去重 | 多次收到 get_history 时按既有 timeline 去重防重复渲染 | chat_session_cubit.dart:582 |
| UI 层 | History* 消息本身不渲染（SizedBox.shrink），只消费其内的 ServerMessage | widgets/message_bubble.dart:221-223 |

**核心洞察**：官方没有「恢复」这个概念——就是把 bridge 里的消息序列**重放一遍**，走与实时完全相同的消费管道。没有第二事实源，所以没有漂移。

## 2. 我们现状与差距

| 环节 | 官方 | claudio 现状 | 差距 |
|------|------|-------------|------|
| 恢复请求 | 连接/resume 后主动 get_history(_delta) | ❌ 无此请求 | 新增 |
| 响应解码 | HistoryDelta/Snapshot → entries | ❌ 无 | CCPocketProtocol 加模型 |
| 消费 | 与实时同管道重放 | ❌ 无；本地快照路径独立成第二事实源 | 核心改造 |
| 渲染 | ServerMessage → 与实时同构 | ChatStore 快照路径（4571）优先于 parts | 远端切换为 history 渲染 |
| 本地 DB | 缓存 + 离线队列 | 恢复权威源 | 降级为缓存 |
| 已有地基 | — | get_history 仅用于身份校验（gap list 中优先级3）；RemoteAgentProvider/CCPocketClient 连接/重连/离线队列已对齐官方 | 复用连接层 |

## 3. 设计

### 3.1 数据流（目标态）

```
杀后台重进 / 切回会话
  → RemoteAgentProvider.ensureSessionStarted（已有，resume 不变）
  → CCPocketClient.send(get_history / get_history_delta)      [新增]
  → bridge 回 HistorySnapshot/Delta
  → CCPocketClient 解码 → 新事件 .historyReplay([ServerMessage])  [新增 AgentStreamEvent case]
  → RemoteAgentProvider 把 ServerMessage 映射为引擎事件序列：
      assistant content 数组 → contentBlockStart(.text/.thinking)/textDelta/thinkingDelta/toolUse/toolResult（与实时同构）
  → 引擎/渲染零改动消费（同一条 SSEStream switch）✅ 共享层红利
  → 持久化：重放产物照常落库（DB 角色从「权威」降为「缓存/离线兜底」）
```

### 3.2 模块改动清单

| 文件 | 改动 | 量级 |
|------|------|------|
| `Providers/CCPocketProtocol.swift` | HistoryEntry/HistoryDelta/HistorySnapshot 解码模型 | 小 |
| `Providers/CCPocketClient.swift` | `requestHistory(sessionId, sinceSeq?)` + 响应路由 + delta-unsupported fallback + **seq 持久化**（对应官方 cachedHistorySeq） | 中 |
| `Providers/RemoteAgentProvider.swift` | ServerMessage → 引擎事件映射（重放模式：抑制 TTS/滚动/标题生成等副作用） | 中 |
| `Providers/AgentProvider.swift` | `AgentStreamEvent.historyReplay` case | 小 |
| `Agent/Chat/AIChatViewModel.swift` | 重放期间进入「backfill 模式」：不滚动、不 TTS、不触发标题/预检 | 中 |
| `Agent/Chat/ChatStore.swift` | 远端消息恢复入口改为「等 history 回填再渲染」，本地快照路径对 remote 退役（保留给本地 agent） | 大（核心） |
| 持久化 | 重放消息按现有 buildRawMessage 落库；raw 上打 `source=bridgeReplay` 标记，避免与本地缓存重复 | 小 |

### 3.3 关键语义决策（对齐官方，不自创）

1. **拉取时机**：连接建立 + 会话 resume 完成后拉一次；重连后按本地 seq 发 delta（官方 bridge_service.dart:2840 同款）
2. **渲染管道统一**：历史消息走实时同一条事件管道（官方 cubit 同构）——**不新增恢复专用渲染路径**，快照路径对 remote 直接退役
3. **去重**：重放落库前按 (bridge message 唯一 id / seq) 查重；同一 sessionId 重复 get_history 不重复渲染（官方 582 同款）
4. **离线语义**：bridge 不可达 → 会话显示「无法加载历史（离线）」占位，**不回退到本地快照渲染**（官方同款代价，pp 已接受）；离线队列（pendingInputs）照常工作
5. **seq 持久化**：per-instance UserDefaults 存 cachedHistorySeq（官方 _runtimeStore 对应物），重连 delta 请求的 sinceSeq 来源
6. **流式冲突**：重放进行中若用户发新消息 → 先完成重放再进输入队列（官方会话 busy 语义，M3 审批前维持 bypass）

### 3.4 明确不做（本轮）

- 不改本地 agent 恢复（uiSequence 快照留任本地，a9c67f4 已修可靠）
- 不做 ProjectHistoryMessage / 跨项目历史（官方另有机制，远端单会话用不到）
- 不动 Bridge Server（规则红线）

## 4. 验证（C-4 对照表模板预填）

```
官方行为（源码位置）：重放与实时同管道（chat_session_cubit.dart:289-316），
  历史渲染无专用路径；连接后主动拉取（bridge_service.dart:2840-2850）
我们现状：本地 uiSequence 快照为恢复权威源（第二事实源，已出漂移事故）
差异分类：☑必须对齐（结构性）
验证方式：
  V1 杀后台重进 → 正文/思考/工具逐块与杀后台前一致（多段多轮任务）
  V2 重连后仅拉 delta（抓包/日志确认 sinceSeq 生效），不重复渲染
  V3 bridge 重启后旧 sessionId 失效 → 走 fallback 全量，渲染完整
  V4 离线重进 → 占位提示 + 不回退快照 + 在线后恢复
  V5 本地 agent 全程回归（验证点 R）——确认快照路径未受损
出包验证点：V1-V5 逐条对应官方行为，由 pp 真机实测
```

## 5. 风险与开放问题

1. **消息管道改动量最大的一块在 ChatStore 恢复入口**——建议拆两步：先「重放渲染 + 快照并存（远端渲染以 history 为准）」，验证后再删远端快照路径（小步原子提交）
2. 重放事件序列对引擎状态机的边界（重放中途 done？）——实现时按官方 _applyUpdate 幂等性对照
3. **开放问题 pp 拍板**：本地 DB 里 remote 旧会话（历史消息）在 A 上线后首次加载时，若 bridge 端 seq 对不上（bridge 重启丢 seq），是否接受「全量重拉覆盖本地缓存」？（官方语义=接受）
