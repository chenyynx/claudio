# Claudio 开发规则 + 验证流程

> Claude Code 自动加载。改 Claudio（OpenMinis 改造）代码前必读。
> 配合 claudio-preflight.md（产品定位/行为边界）一起看。

## 🔴 会话状态自动加载（pp 2026-08-31 定）

动 Claudio 前**先读 CC 记忆状态文件**（含会话断点追踪区：会话 ID + 最后进度 + 时间线）：
`/home/ubuntu/.claude/projects/-home-ubuntu/memory/claudio-project-state.md`

- 会话中断/续档：状态文件顶部「🕐 会话断点追踪」区直接续，不翻聊天记录
- 每完成一步改动（代码/配置/修复/出包）：往状态文件追加一行 `时间 + 动作 + 会话ID`（会话 ID 取 `ls -lt ~/.claude/projects/-home-ubuntu/*.jsonl` 最新文件）
- 进度状态只进 CC 记忆，**不进 claudio 仓库**

---

## 一、改造范围

### 能动的（OpenMinis iOS 端 `src/ios/`）

| 层 | 文件/模块 | 干什么 |
|----|----------|--------|
| Provider 层 | `Providers/` 加 `RemoteAgentProvider.swift` + ProviderType 扩展 | 远端 agent 通道入口（照 LLMProvider 协议实现） |
| 连接层 | 新增 WebSocket 客户端（扫码配对/连接/断线重连） | 照 CC Pocket 公开协议写 |
| 展示层 | 审批弹窗 + 轨迹页（其余复用现成 UI） | C 档完整管道 |

### 不动的

- 🔴 OpenMinis 核心：iSH 沙箱、设备桥接、Skills 加载器、本地 agent 引擎——保留资产，不碰
- 🔴 Bridge Server（用户机器侧）：用现成 npm 包，不 fork 不改
- 🔴 agent CLI（Claude Code/Codex）：不魔改、不碰用户凭证/env/MCP
- 🔴 上游 OpenMinis 其他模块：只加不改，改动前先确认归属

## 二、验证流程（iOS，无 Mac）

```
本地改动 → 静态检查（Swift 语法/类型）→ git push 私有仓库
→ GitHub Actions macOS 构建 → 出包 → 你 iPhone sideload（7 天签名）→ 实测反馈
```

### CI 构建经验（2026-08-30 踩坑总结，OpenMinis 首次构建必读）

OpenMinis 的构建 = 构建时生成全部原生依赖（官方文档 BUILDING.md 是"本地 Mac 指南"，CI 场景有 3 个文档没写的坑）：

1. **checkout 必须 `submodules: recursive`**（deps/ish、deps/proot 是子模块）
2. **xcconfig 从模板生成**：`cp src/ios/Configs/ProviderCustomization.xcconfig.example .../ProviderCustomization.xcconfig`（私有配置不提交）
3. **沙箱资源 stub**（M1 不跑沙箱）：`touch deps/resources/alpine-rootfs.zip` + `mkdir deps/resources/RootfsPatch.bundle`——跑本地 agent 前必须真跑 `./deps/prepare_alpine_rootfs.sh`
4. **工具链全 brew**：`brew install meson ninja llvm lld libarchive pkg-config`——🔴 **lld 必须单独装**（2026 年 Homebrew 把 lld 从 llvm 拆成独立 formula，只装 llvm 时 VDSO 报 `invalid linker name in argument '-fuse-ld=lld'`）；🔴 不要用 pip3（runner Python 是 PEP-668 受管环境，报 externally-managed-environment）
5. **PATH 前置 brew LLVM**：`export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:$PATH"`——VDSO 编译用 clang 找 lld，meson 从 PATH 取 clang
6. **deps 构建顺序**：`./deps/build_lame.sh && ./deps/build_ffmpeg.sh && ./deps/build_ish.sh`（FFmpeg 链接 LAME，顺序不能乱；iSH 构建 10-20 分钟）
7. **xcodebuild 用官方写法**：`-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData`
8. 私有仓库配额（2000 分钟/月，macOS 10x）→ **攒里程碑构建，小改动别触发**；push 会触发构建，改 workflow 时注意别浪费并行构建

workflow 参考：`.github/workflows/ios-build.yml`（已含全部坑的修复）

### 私有仓库配额铁律（Free 计划 2000 分钟/月，macOS 10x）

- 🔴 **攒里程碑构建**：不是每轮小改都触发 iOS 构建。小改动用本地能做的检查（读代码/静态分析/单元测试逻辑推演）代替
- 一次 iOS 构建 ≈ 100-200 分钟配额 → 每月最多 10-20 次 → 按里程碑（M0-M4）分配
- 配额不够 → 一键切公开仓库（构建无限免费），GPL 反正最终要公开

### 免费 Apple ID sideload 现实

- 签名 7 天过期、无限重签、同时最多 3 个 App
- CI 里免费账号签名 = 手动导出证书上传 secrets，每 7 天重新导出（M0 要留时间做）

## 三、开发铁律

1. **动手前先复述理解。** 用户没确认前不写代码。不懂就问清楚——"没明白就先问"是用户 2026-08-30 明说的
2. **改动清单先拍板。** 每次动手前给清单（改哪些文件、加什么、为什么），用户确认后才动
3. **模块化。** 单文件 ≤200 行、模块边界清晰、禁止死代码/内联重复/中间 import（对齐开发规范）
4. **最小改动。** 只改本次任务必需的文件和行，不顺手"统一风格"
5. **GPL 意识。** App 内所有新代码都要开源——注释/命名按开源标准写，不写 proprietary 标记
6. **协议照抄 K9i-0/ccpocket 公开文档。** 不自创消息格式；看不懂协议先查文档（stack.md），不猜。⚠️ heypandax/cc-pocket 是同名不同项目，已排除（见 preflight 决策记录 0）
7. **Bug 入库。** 修复完成 → 查 Bug经验库 → 判定是否入库 → 入库后才告知"修好了"
8. **会话状态。** 会话结束时更新本仓库会话状态（文件列表/行数/已知限制/下一步）
9. **UI 改动先列问题清单。** 对齐行为规范：UI/动画/布局改动不许边改边试

## 四、里程碑清单（当前进度）

| 里程碑 | 内容 | 状态 |
|--------|------|------|
| M0 | 私有仓库 + GitHub Actions iOS 构建跑通 + Bridge 部署腾讯云（nginx wss）+ CC Pocket 官方 App 实测管道 | 未开始 |
| M1 | RemoteAgentProvider + WebSocket 客户端，流式正文/思考显示 | 未开始 |
| M2 | 工具调用卡片渲染 | 未开始 |
| M3 | 审批弹窗（允许/拒绝/记住选择） | 未开始 |
| M4 | 轨迹页 + 断线重连打磨 | 未开始 |

## 五、待确认事项（不阻塞开发，但记着）

- 付费 Apple Developer 账号（$99/年）：上架前必须，开发期免费 ID 顶着
- 正式产品名（Claudio 为工作名，上架前最终定）
- 托管 Bridge 服务（商业化可选，第一版不做）

## 三-B、Swift 代码改动前置检查（2026-08-31 新增，M1 编译失败教训）

1. **改 Swift 前加载 `swiftui-pro` skill** 走 `references/swift.md` 语法/规范核查，再 push
2. **禁止 guard 条件里一行大链式 + 多行闭包 + optional chaining `?` 跨行组合**——Swift 解析会崩（`$0` 逃出闭包 / guard 缺 else / consecutive statements），改拆步写法：先 `let` 绑定中间结果，guard 只放单表达式，链式放普通赋值
3. **本地（Linux）无 Swift 工具链**，编译验证只能靠 CI（13 分钟/轮）——push 前人工语法检查至少过一遍
4. 详细条目见 Bug经验库/状态与数据.md「Claudio M1 — last user message 提取失败」教训⑤⑥

## 三-C、完全对齐官方执行协议（2026-08-31 新增；2026-09-01 pp 定稿，含翻车根因三连）

### C-0. 总纲

**🔴 全部功能完全照着 ccpocket 官方实现（pp 2026-09-01 定）**：Claudio 的远端通道本质是用 CC Pocket 的能力，**远端通道的全部功能**（连接、重连、resume、会话生命周期、消息队列、事件消费、工具调用、审批、历史、文件浏览、错误处理、UI 交互）都以 K9i-0/ccpocket 官方客户端为唯一基准照着实现。**不允许凭自己理解"设计"行为，不允许只照抄消息格式，不允许官方有的功能我们不做、官方没有的行为我们自创。** 对照不到的功能先问 pp，不自己拍板。

### C-1. 翻车根因三连（2026-09-01 pp 点名，防再犯）

1. **子代理审计清单 ≠ 自己读官方代码**：前几轮派子代理审计官方源码，输出"功能有无"清单（有重连 ✅ 有 resume ✅）→ 漏了"重连时发不发 resume"这个行为细节 → 进程堆积修了几轮没根治。**主代理必须亲自打开官方源码对应文件/函数读，不依赖子代理清单。**
2. **"目标症状消失" ≠ "和官方一致"**：每轮修完只验证"连续消息还新开会话吗"，过了就宣布完成。正确完成标准 = C-4 行为对照表全部填完且差异分类完毕。
3. **"照协议写"被理解成"照消息格式写"**：公开协议文档（stack.md）只讲 wire 格式，**行为语义在官方客户端代码里**。任何行为问题先找官方实现，不靠协议文档猜。

### C-2. 动手前置（每项远端通道功能开工前必做）

1. 在官方源码定位对应实现：`/tmp/ccpocket-main`（已 clone），核心文件
   - `apps/mobile/lib/services/bridge_service.dart`（连接/重连/队列/会话生命周期）
   - `apps/mobile/lib/features/claude_session/claude_session_screen.dart`（会话 UI 行为）
   - `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart`（消息发送/事件消费/思考显示）
   - `apps/mobile/lib/features/codex_session/` + `features/session_list/`（其他功能域）
2. 通读官方对应函数后，在注释里写明"对齐官方 xxx.dart:yyy"再写自己的代码
3. 写之前给 pp 报"官方怎么做的 + 我们差异 + 改法"（铁律 1）

### C-3. 行为基准表（已对齐的行为快照，改动不得破坏；新对齐的随时追加）

| 行为 | 官方基准（源码位置） | 我们的实现 |
|------|---------------------|-----------|
| 断线重连 | 只重连 socket + 重放离线队列，**不重新 start/resume**（bridge_service.dart onDone→_scheduleReconnect→connect→_flushMessageQueue） | reconnectNow：teardownSocket + connect + flushPendingInputs（3e78947 对齐） |
| resume_session 时机 | 仅冷启动打开会话 / 离线动作队列重放（bridge_service.dart:1898 OfflinePendingAction.kind=resume） | 仅 provider 第一轮 ensureSessionStarted（RemoteAgentProvider） |
| 断线消息 | 入队（去重 by clientMessageId）+ 持久化 + 重连后重放（bridge_service.dart _queueOfflineMessage/_persistOfflinePendingMessages） | pendingInputs + UserDefaults + flushPendingInputs |
| 回前台 | ensureConnected：连接活着只刷新，不重连（claude_session_screen.dart:791） | ensureConnected 同款 |
| session_created | 只认匹配自己 requestId 的回复（bridge 广播所有会话消息） | captureSession isOurs 过滤 |
| thinking 显示 | 有内容即显示，**无显示开关**（chat_session_cubit.dart:999） | 流式直接显示；恢复默认显示 ?? true（3e78947 对齐） |
| result/stopped | 正常结束 turn（bridge_service.dart:847） | handleIncoming → endTurn（已有） |
| session_resume_failed | 中止等待（bridge_service.dart:819） | resumeFailure → abort（已有） |

### C-4. 修复完成标准（替代"症状消失即完成"）

任何远端通道修复，宣布完成前必须填完对照表：

```
官方行为（源码位置）：____
我们现状：____
差异：____
差异分类：□必须对齐（根因） □设计差异（写明理由） □低优先级（记待办）
验证方式（必须能证明与官方一致）：____
```

- **必须对齐**的差异 → 本轮修掉
- **设计差异**（如 stopped 后从会话列表移除=会丢本地历史）→ 写明理由，不照抄
- **低优先级**（如 baseSeq 多端冲突检测）→ 记入状态文件待办
- 表没填完 = 修复没完成，不许说"修好了"

### C-5. 已知差异待办（对照官方遗留，M4 断线恢复完整化时处理）

1. **baseSeq 冲突检测**：官方离线重放带 cachedSessionHistorySeq（chat_session_cubit.dart:1366）防多端并发冲突；需完整 history-seq 跟踪，单用户场景低优先级
2. **离线队列存 start/resume 动作**：官方断线期间的 resume 也入队重放（bridge_service.dart:1898）；我们 resume 只在 provider 第一轮发，断线恰逢第一轮 resume 时 fallback start 可能开新会话（低概率）
3. **bridge 重启后旧 sessionId 失效**：重放失败消息 re-queue 不丢，官方靠 resume 动作重放恢复
4. **官方无应用层 ping**：我们保留 30s ping（iOS 后台 WS 假死检测有价值，重连不再 spawn 后无害）
