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

## 三-C、协议客户端实现铁律（2026-08-31 新增，M1 五连坑教训；2026-09-01 升级为"完全对齐"）

1. **🔴 全部功能完全照着 ccpocket 官方实现（pp 2026-09-01 定）**：Claudio 的远端通道本质是用 CC Pocket 的能力，**远端通道的全部功能**（连接、重连、resume、会话生命周期、消息队列、事件消费、工具调用、审批、历史、文件浏览、错误处理、UI 交互）都以 K9i-0/ccpocket 官方客户端为唯一基准照着实现——**不允许凭自己理解"设计"行为，不允许只照抄消息格式，不允许官方有的功能我们不做、官方没有的行为我们自创**。任何功能动手前先找到官方对应代码（本地参考：`/tmp/ccpocket-main`，核心文件 `apps/mobile/lib/services/bridge_service.dart` + `features/claude_session/claude_session_screen.dart` + `features/codex_session/` + `features/session_list/`），对照官方怎么写再写；对照不到的功能先问 pp，不自己拍板
2. **🔴 重连语义必须对齐官方（2026-09-01 实测翻车教训）**：官方断线重连 = **只重连 socket + 重放离线消息队列**，**不重新 start/resume**（session 是 bridge 侧常驻资源，进程 idle 30 个内不驱逐，重连只是"把管子接回去"）；`resume_session` 只在 ① 冷启动打开会话 ② 离线队列重放时发送。之前每次重连都 resume/start → bridge 每次 spawn 新进程 → 进程堆积 + 会话记录膨胀（修了几轮没根治，根因就是重连语义没对齐）
3. **审计必须查"行为细节"不是"功能有无"**：对照官方时逐项问"什么时候发什么消息、什么条件下触发"，不能只核对"有没有重连、有没有 resume"这种表面功能（2026-09-01 教训：重连/resume 都"对齐"了，但"重连时发不发 resume"没对齐，导致进程堆积问题反复）
4. **"最小能跑"不是 M1 终点**——重连、会话恢复、事件去重、持久化是客户端基础能力，不是后期优化。M1 五连坑（文字不显示/消息重复/断连/会话丢失/标题污染）全是这些能力缺失
5. **新增协议功能前自问**：官方客户端这个场景怎么处理？找不到答案不写代码
