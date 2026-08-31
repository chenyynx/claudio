# CC Pocket 消息链路对齐审计 — 差距清单（28 项）

> 2026-09-01 对抗审计产出（对照 K9i-0/ccpocket 官方 Flutter 客户端 + Bridge 源码实锤）。
> 贯穿结论：官方 = "Bridge 会话是唯一真相"（session_list 驱动、按 sessionId 路由、history 回填、离线队列补传输）；claudio 旧版 = "本地会话是真相、Bridge 是盲管道"。
> 状态图例：✅ 已修（commit） | 📌 待修（优先级） | 🎯 里程碑项

## 必须修（9 项，✅ 已全部修复 9153e16→2e672a2）

| # | 差距 | 状态 |
|---|------|------|
| 1 | 陈旧 sessionId 优先（`sessionId ?? client.sessionId` 反了）→ input 路由死会话 | ✅ |
| 2 | handler 安装竞态（先 sendInput 后装 onMessage）→ 丢 result/无限转圈 | ✅ |
| 3 | "No active session"死锁（不自动重 start） | ✅ |
| 4 | 断线不自动重连 + 无前台恢复（ping 失败不处理） | ✅ |
| 5 | 无离线队列（断线丢消息） | ✅ |
| 6 | 单闭包 handler + 会话无归属映射 | ✅（归属映射已做；多会话并发仍受引擎串行约束） |
| 7 | claude id 按 projectPath 存（应按 instance 映射/仿官方不存） | ✅（ccpocket.sessionMap.v1.<instance>） |
| 8 | 无 stop_session/interrupt、stopped 不处理 | ✅（interrupt 已做；stop_session 已删——M2 停止按钮需要时再加） |
| 9 | 错误路径 thinking 丢失 | ✅（Case1/2 落盘 + error 路径 yield） |

## 中优先级（5 项，✅ 已修）

| # | 差距 | 状态 |
|---|------|------|
| 1 | start 与 connect 解耦（打开 App 不拉起 agent） | ✅ |
| 2 | resume_session 官方流程（带 resume 单飞/失败通知） | ✅（含 session_resume_started 延长等待防竞态） |
| 3 | get_history 回填与本地 DB 对齐 | 📌 部分：仅用于身份校验；本地 DB 回填未做（需动共享层） |
| 4 | input_ack/rejected 状态机（投递状态可见+重发） | ✅（ack 移除队列；UI 状态展示未做） |
| 5 | 快照 vs delta 去重精修（大 chunk 尾部截断） | ✅ 引擎层有终稿覆盖兜底（StreamEnd FINAL FLUSH），provider 不做 |

## 低优先级 / 里程碑（14 项，🎯 未修）

| # | 差距 | 归属 |
|---|------|------|
| 1 | tool_result 渲染为工具结果卡片 | 🎯 M2（引擎无 toolResult 事件类型，需扩展 AgentStreamEvent） |
| 2 | 审批链路（permission_request approve/reject） | 🎯 M3（当前锁死 bypassPermissions 规避） |
| 3 | baseSeq 冲突检测（rewind/分支基础） | 🎯 M4 |
| 4 | conversation_queue 状态 UI（"已排队"显示） | 🎯 低 |
| 5 | user_input 回显 UUID 关联（rewindable） | 🎯 低 |
| 6 | 重发消息去重（clientMessageId 桥端不去重） | 🎯 低（官方同风险） |
| 7 | 多本地会话各自独立 bridge session | 🎯 M2 前 UI 双入口隔离 |
| 8 | 同桥多客户端 busy 检测/警告 | 🎯 中（当前靠接收过滤兜底） |
| 9 | 会话 status=busy 时冲突提示 | 🎯 中 |
| 10 | 断线期间消息持久化队列跨重启恢复 | ✅ 已做（pending.v1 key） |
| 11 | stop_session 完整实现（用户停止会话按钮） | 🎯 M2 |
| 12 | 前台恢复主动检查连接（scenePhase） | 📌 待做（现靠 ensureConnected + send 失败兜底） |
| 13 | permissionMode 非 bypass 时 permission_request 处理 | 🎯 M3 |
| 14 | 离线 start/resume 入队 | 🎯 低 |

## 历史遗留（已不适用）

- 旧 `ccpocket.agentSession.v1.<projectPath>` UserDefaults 残留（8 位 bridge id / 脏 claude id）——新代码不再读写，无需清理逻辑（mapping key 全新）

## 验证记录

- 2026-09-01 pp 实测日志（665483d 包）：✅ resume 同会话 ✅ 连续消息同一 bridge session ✅ 接收过滤生效 ✅ 心跳重连 ✅ saveMapping 自动持久化
- 2026-09-01 发现 resume 超时竞态（session_resume_started 后 10s 超时 → fallback start 交错）→ 2e672a2 修复（等待窗口延长至 30s）
