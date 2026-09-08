# Claude Authentication Troubleshooting

[日本語版](auth-troubleshooting.ja.md) | [简体中文版](auth-troubleshooting.zh-CN.md) | [한국어](auth-troubleshooting.ko.md)

CC Pocket uses `ANTHROPIC_API_KEY` by default. Subscription authentication is
disabled unless the Bridge operator explicitly sets
`BRIDGE_ALLOW_CLAUDE_OAUTH=1` and restarts Bridge.

## Why Subscription Authentication Requires Opt-In

Anthropic's [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
page says its Commercial Terms do not prevent a platform from hosting the
unmodified Claude Code binary when each end user signs in with their own
subscription or other credentials, subject to the conditions listed there.
CC Pocket similarly runs the official Claude Agent SDK on the user's Bridge
machine and delegates authentication to the host's Claude Code environment.
CC Pocket does not copy, store, or refresh Claude OAuth credentials itself.

The host-side Claude Code pattern is also used by similar remote tools such as
[OpenClaw](https://github.com/openclaw/openclaw/blob/main/docs/concepts/oauth.md),
[Happy](https://github.com/slopus/happy), and
[Termopus](https://github.com/Termopus/termopus), although their exact
implementations differ.

However, Anthropic's [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk)
also directs unapproved third-party products to API keys instead of Claude.ai
login or subscription rate limits. The scope of these statements is not clear
for CC Pocket's architecture, and Anthropic may restrict this authentication
method in the future.

To avoid this uncertainty, configure `ANTHROPIC_API_KEY`. If you understand the
risk and choose subscription authentication, run Bridge with:

```bash
BRIDGE_ALLOW_CLAUDE_OAUTH=1 npx @ccpocket/bridge@latest
```

If subscription authentication then fails, sign in to Claude Code again on the
Bridge machine and restart Bridge.

## If You Are Not Near Your Bridge Machine

With CC Pocket, your Bridge machine may be a Mac mini or another Mac running at home.
Even in that case, you can log back into Claude Code remotely from your phone.

1. Connect to the Bridge machine from a terminal app
   - Moshi, Termius, Blink, or any SSH client works
2. Run `claude`
3. Run `/login` inside Claude Code
4. Open the displayed URL on your phone or PC
5. Complete sign-in in the browser
6. Paste the result back into the terminal if prompted

CC Pocket will use the updated login on the next request.

## If You Are Near Your Bridge Machine

1. Run `claude` on the Bridge machine
2. Run `/login`
3. Complete the browser sign-in flow

## Shell Alternative

If you prefer, you can also run:

```bash
claude auth login
```

## When This Happens

- Your Claude login expired
- Claude Code was updated and the old login became invalid
- Anthropic revoked the saved token
