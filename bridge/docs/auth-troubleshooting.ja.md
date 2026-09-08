# Claude 認証トラブルシューティング

[English](auth-troubleshooting.md) | [简体中文版](auth-troubleshooting.zh-CN.md) | [한국어](auth-troubleshooting.ko.md)

CC Pocket はデフォルトで `ANTHROPIC_API_KEY` を使います。サブスクリプション認証は、
Bridge 管理者が `BRIDGE_ALLOW_CLAUDE_OAUTH=1` を明示的に設定して Bridge を
再起動した場合のみ有効になります。

## サブスクリプション認証に明示的な有効化が必要な理由

Anthropic の [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
には、記載された条件のもと、未改変の Claude Code をプラットフォーム上で実行し、
各ユーザーが自分のサブスクリプションなどでログインすることを Commercial Terms は
妨げない、という記載があります。CC Pocket もユーザー自身の Bridge マシン上で公式
Claude Agent SDK を実行し、ホストの Claude Code 環境へ認証を委譲します。CC Pocket が
OAuth 認証情報をコピー、保存、更新することはありません。

ユーザーの PC 上で Claude Code を動かして遠隔操作する方式は、
[OpenClaw](https://github.com/openclaw/openclaw/blob/main/docs/concepts/oauth.md)、
[Happy](https://github.com/slopus/happy)、[Termopus](https://github.com/Termopus/termopus)
などの類似ツールでも採用されています。ただし、具体的な実装はそれぞれ異なります。

一方、Anthropic の [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk) には、
事前承認のない第三者製品では Claude.ai ログインやサブスクリプション枠を提供せず、
API キーを使うよう案内する記載も残っています。これらの記載が CC Pocket の構成へ
どう適用されるかは明確でなく、将来この認証方式が制限される可能性があります。

この不確実性を避ける場合は `ANTHROPIC_API_KEY` を設定してください。リスクを理解したうえで
サブスクリプション認証を選ぶ場合は、次のように Bridge を起動します。

```bash
BRIDGE_ALLOW_CLAUDE_OAUTH=1 npx @ccpocket/bridge@latest
```

有効化後に認証エラーが出た場合は、Bridge マシンで Claude Code に再ログインして
Bridge を再起動してください。

## 手元に Bridge マシンがない場合

CC Pocket では、自宅の Mac mini や別の Mac を Bridge マシンとして動かしていることがあります。
その場合でも、iPhone などから遠隔で Claude Code に再ログインできます。

1. ターミナルアプリから Bridge マシンに接続
   - Moshi, Termius, Blink などで SSH 接続します
2. `claude` を実行
3. Claude Code の中で `/login` を実行
4. 表示された URL を iPhone や PC のブラウザで開く
5. サインインを完了する
6. 必要なら結果をターミナルに貼り付ける

次のリクエストから、CC Pocket が新しいログイン状態を使います。

## 手元に Bridge マシンがある場合

1. Bridge マシンで `claude` を実行
2. `/login` を実行
3. ブラウザでサインインを完了する

## シェルから実行する方法

対話画面を開かずに、次のコマンドでも再認証できます。

```bash
claude auth login
```

## よくある原因

- Claude Code のログイン期限が切れた
- Claude Code の更新で以前のログイン情報が無効になった
- Anthropic 側で保存済みトークンが失効した
