# Claudio 开发规则 + 验证流程

> Claude Code 自动加载。改 Claudio（OpenMinis 改造）代码前必读。
> 配合 claudio-preflight.md（产品定位/行为边界）一起看。

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
