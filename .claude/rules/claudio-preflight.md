# Claudio 产品架构 + 行为边界

> Claude Code 自动加载。每次碰 Claudio（OpenMinis 改造）前内化，防止跑偏。
> 独立项目，与 Codios 无归属关系。

---

## 一、产品是什么

**Claudio = OpenMinis 改造版，独立产品，目标 App Store 上架。**

- 名字由来：Claudio 是 Claude 的意大利语版——这 App 连的就是 Claude Code，名字即叙事
- 定位：**开发者向**。第一版目标用户 = 已经有自托管 agent 环境（电脑/服务器跑 Claude Code / Codex）的开发者 / AI 重度用户
- 形态：**混合二合一**——保留 OpenMinis 全部本地能力（iSH 沙箱、30+ 设备桥接、Skills、模型钥匙串）+ 新增"连自己机器上 agent"的远端通道
- 卖点：手机原生能力 + 自托管 agent 算力二合一；**无云直连**（agent 跑在用户自己的机器上，数据不经任何第三方）
- 商业模式：第一版免费开源（GPL），先跑通功能；未来可选项 = 托管 Bridge 服务（用户自托管始终免费），暂不锁死

## 二、系统架构

```
┌─────────────────┐     ┌──────────────────────────┐
│  用户手机         │     │  用户自己的机器（电脑/服务器） │
│                  │     │                          │
│  Claudio App     │◄───►│  Bridge Server（现成）     │
│  (OpenMinis fork)│ WS  │  (CC Pocket, npm 包)      │
│  Swift/SwiftUI   │     │  ├─ 适配器: Claude Code  │
│                  │     │  └─ 适配器: Codex        │
│ - 本地 agent 保留 │     │  （agent CLI 跑在这台机器） │
│ - 远端 agent 通道 │     │                          │
└─────────────────┘     └──────────────────────────┘
     无第三方，手机 ↔ 用户机器直连（JSON WebSocket 公开协议）
```

### 数据流（远端对话）
```
手机发消息 → WS → Bridge → 用户机器上的 agent CLI（Claude Code/Codex）
用户看到 ← WS ← Bridge ← 事件流（正文/思考/工具调用/结果/审批）
```

### 各层归属

| 层 | 谁的东西 | 规则 |
|----|----------|------|
| **手机 App**（Claudio） | 我们的产品，改的主战场 | provider 层 / 连接层 / 展示层 |
| **Bridge Server** | 现成开源（CC Pocket，MIT），跑在用户机器上 | 🔴 直接用 npm 包，不 fork 不改 |
| **agent CLI**（Claude Code/Codex） | 用户自己的 AI | 🔴 不碰凭证/env/MCP，不魔改 CLI |

## 三、决策记录（2026-08-30 定）

1. **本地/远端关系**：各用各的（两个独立入口，用户自选），第一版不做协同
2. **协议**：照 CC Pocket 公开 JSON WebSocket 协议写客户端，**通用事件模型**（正文/思考/工具调用/结果/审批，不绑死 agent）——预留多 agent
3. **第一版实际接**：Claude Code + Codex（Bridge 现成适配器，零代码）；DSH 等有需求再做
4. **档位**：C 档完整管道（工具调用卡片 / 审批按钮 / 轨迹页），一步到位
5. **验证**：iOS 走 GitHub Actions 云构建 → sideload（免费 Apple ID，7 天签名）；付费开发者账号（$99/年）上架前再买
6. **仓库**：开发期私有（`chenyynx/claudio`），upstream 走 gh-proxy 镜像；配额不够或上架时切公开
7. **目标用户**：开发者向
8. **UI 复用**：聊天界面/工具卡片 = OpenMinis 现成；配对页 = dsh-mobile 移植（MIT）；要写的只有审批弹窗 + 轨迹页
9. **里程碑**：M0 基建（Bridge 部署 + 构建流水线）→ M1 协议客户端（流式对话）→ M2 工具展示 → M3 审批 → M4 轨迹+打磨

## 四、核心铁律

1. 🔴 **Agent 是用户自己的 AI。** key、env、MCP、工具、agent CLI 全是用户的，跑在用户机器上。我们只做管道（手机端 + 转发），不碰用户的任何配置。
2. 🔴 **Bridge 用现成。** CC Pocket Bridge Server 直接 `npx @ccpocket/bridge` 用，不 fork、不改源码。想加 agent 适配器 = 上游 CC Pocket 的活，最多提 PR。
3. 🔴 **协议不自创。** 手机端照 CC Pocket 公开协议写，不自造消息格式、不魔改 wire 协议。
4. 🔴 **GPL 合规。** App 本体基于 OpenMinis fork（GPL-3.0），App 内**所有代码（含新写）必须开源**。服务端/网关（Bridge 独立进程，MIT）不传染。上架时提供源码（仓库切公开）。
5. 🔴 **License 边界。** dsh-mobile（MIT）代码可移植进 App；CC Pocket 是 Flutter，代码不能搬（跨语言），只参考协议。
6. 🔴 **不碰本地 agent 核心。** OpenMinis 的沙箱/iSH/设备桥接/Skills 是保留资产，不动其核心逻辑，只加远端通道。

## 五、判断标准

动手前问自己：

1. **这行代码跑在谁的机器上？** 手机（Claudio App）→ 改；用户机器（Bridge/agent）→ 不动
2. **我是在管管道，还是在管用户的东西？** 管道（协议/连接/展示）→ 修；用户的东西（凭证/env/agent 配置）→ 停手
3. **这是通用产品逻辑还是 pp 特供？** 通用 → 改源码；pp 特供（腾讯云部署等）→ 只写运维配置，不进产品代码
