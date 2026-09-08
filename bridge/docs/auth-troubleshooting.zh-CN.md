# Claude 认证故障排查

[English](auth-troubleshooting.md) | [日本語版](auth-troubleshooting.ja.md) | [한국어](auth-troubleshooting.ko.md)

CC Pocket 默认使用 `ANTHROPIC_API_KEY`。只有 Bridge 管理员明确设置
`BRIDGE_ALLOW_CLAUDE_OAUTH=1` 并重启 Bridge 后，订阅认证才会启用。

## 为什么订阅认证需要明确启用

Anthropic 的 [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
页面写明，在满足其中所列条件时，Commercial Terms 不会阻止平台托管未经修改的
Claude Code，并允许每位最终用户使用自己的订阅或其他凭据登录。CC Pocket 同样在用户自己的
Bridge 机器上运行官方 Claude Agent SDK，并将认证交给主机上的 Claude Code 环境。
CC Pocket 本身不会复制、保存或刷新 Claude OAuth 凭据。

在用户电脑上运行 Claude Code 并进行远程控制的方式，也被
[OpenClaw](https://github.com/openclaw/openclaw/blob/main/docs/concepts/oauth.md)、
[Happy](https://github.com/slopus/happy) 和 [Termopus](https://github.com/Termopus/termopus)
等类似工具采用，但具体实现并不完全相同。

另一方面，Anthropic 的 [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk)
仍要求未经批准的第三方产品使用 API 密钥，而不是提供 Claude.ai 登录或订阅额度。
这些说明如何适用于 CC Pocket 的架构并不明确，Anthropic 未来也可能限制这种认证方式。

若要避免这种不确定性，请设置 `ANTHROPIC_API_KEY`。如果你理解风险并选择订阅认证，请运行：

```bash
BRIDGE_ALLOW_CLAUDE_OAUTH=1 npx @ccpocket/bridge@latest
```

启用后若订阅认证失败，请在 Bridge 机器上重新登录 Claude Code，并重启 Bridge。

## 当你不在 Bridge 机器旁边时

在 CC Pocket 的使用场景里，你的 Bridge 机器可能是家里的 Mac mini，或者另一台一直开着的 Mac。
即使如此，你也可以直接用手机远程重新登录 Claude Code。

1. 用终端应用连接到 Bridge 机器
   - 可以使用 Moshi、Termius、Blink 或任意 SSH 客户端
2. 运行 `claude`
3. 在 Claude Code 中执行 `/login`
4. 在手机或电脑浏览器中打开显示出来的 URL
5. 完成登录
6. 如果终端提示需要粘贴结果，就把结果贴回去

从下一次请求开始，CC Pocket 就会使用更新后的登录状态。

## 当你就在 Bridge 机器旁边时

1. 在 Bridge 机器上运行 `claude`
2. 执行 `/login`
3. 在浏览器中完成登录流程

## Shell 方式

如果你愿意，也可以直接运行下面的命令：

```bash
claude auth login
```

## 常见原因

- 你的 Claude 登录已过期
- Claude Code 更新后，旧的登录状态失效了
- Anthropic 撤销了已保存的令牌
