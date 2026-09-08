# Git Operations

## Context

Codex App (macOS) のGit操作機能を調査した結果を踏まえ、ccpocketにGit操作機能を追加する。

### 背景

- CodexはsandboxデフォルトONのため、エージェントが `git commit` / `push` / `PR作成` を行えない
- Codex Appの設計思想:「AIはコードだけ書く、gitは人間がアプリのUI経由でやる」
- ccpocketには既にDiff Viewer（ハンク選択・画像diff対応）があるが、その先のアクション（ステージング→コミット→push→PR）がない
- 現状ではSandboxをOFFにしてエージェントにgit操作を任せるユーザーが多いと思われるが、レビューなしの一気通貫になりがち
- アプリ側にGit操作UIを持つことで「AIがコード変更 → 人間がモバイルでレビュー・コミット」というワークフローを実現できる

### Codex App との設計思想の違い

| | Codex App | Claude Code | ccpocket（提案） |
|---|---|---|---|
| Sandbox | デフォルトON | デフォルトOFF | エージェント依存 |
| Git操作の主体 | アプリ（Electron）がUI経由で実行 | エージェントがCLIで直接実行 | アプリ（Flutter）がUI経由で実行 |
| ワークフロー | 会話ごとにworktree自動作成 → AIがコード変更 → 人間がUIでコミット・push・PR | エージェントがgit add/commit/pushまで一気通貫 | セッション完了 → モバイルでレビュー → コミット・push・PR |
| PR作成 | アプリ内UIボタン（`gh` CLI経由） | エージェントが `gh pr create` を直接実行 | アプリ内UIボタン（Bridge経由で `gh` CLI） |

## 段階的リニューアル案

### Phase 1: Diff Viewerの強化（ステージング機能）

既存のハンク選択UIをステージング操作に昇格させる。

```
現状                         リニューアル後
─────────                    ───────────────
ハンク選択 → チャットに送信    ハンク選択 → Stage/Unstage
(確認のみ)                   Staged / Unstaged タブ切替
                             ファイル単位のStage/Revert
                             Stage All / Unstage All
```

- 既存の `DiffParser` と `initialSelectedHunkKeys` の仕組みをそのまま活用可能
- FABの「チャットに送信」に加えて「Stage selected」アクションを追加
- Bridgeに `git add -p` 相当のメッセージハンドラを追加
- モバイルならでは: スワイプでStage/Revert（メールアプリのスワイプ操作のイメージ）

### Phase 2: コミットフロー

Diff Viewerの下部またはボトムシートとしてコミットUIを追加。

```
┌─────────────────────────┐
│  Commit                 │
│  ───────────────────    │
│  Message: [          ]  │
│  (空欄で自動生成)        │
│                         │
│  Staged: 3 files (+42/-8)│
│                         │
│  [Commit]               │
│  [Commit & Push]        │
│  [Commit & Create PR]   │
└─────────────────────────┘
```

- コミットメッセージ自動生成: Bridge経由でCLI単発呼び出し（後述「AI補助」参照）
- 3段階ボタン: Commit / Commit+Push / Commit+Push+PR
- Bridgeに `git commit`, `git push`, `gh pr create` のハンドラを追加

### Phase 3: ブランチ操作

現在の `BranchChip` を拡張してブランチセレクターにする。

- 現在のブランチ表示（既存）→ タップでブランチ一覧シート
- ブランチ検索
- 「新規ブランチ作成」ボタン
- 未コミット変更がある場合の警告ダイアログ
- worktree連携: 新規worktreeで作業する場合のブランチ自動作成

### Phase 4: PRパネル

セッション画面内にPRステータスを表示するウィジェット。

- PRの状態バッジ（Draft / Ready / Merged）
- CI結果のサマリー（Passed / Failed）
- Fix ボタン: CI失敗時にエージェントへ「CIを修正して」と自動送信
- PR URLをタップでブラウザ表示
- Merge ボタン（Squash / Merge 選択）

## モバイル特化の工夫

| Codex App (デスクトップ) | ccpocket (モバイル) |
|---|---|
| Diffパネルを常時横に表示 | 通知でdiff確認を促す → タップでDiff Screen |
| ハンク単位の細かいStage | ファイル単位Stageをデフォルト、ハンクは展開時のみ |
| コミットメッセージ手入力 | 自動生成をデフォルト、編集は任意 |
| PR本文を丁寧に編集 | ワンタップPR作成、本文は自動生成 |
| CI詳細を画面内表示 | CI失敗 → Push通知 → Fixボタンの動線 |
| 複雑なHand-off UI | worktree一覧からスワイプでHand-off |

## `gh` CLI 依存の設計

GitHub連携（PR作成・Merge・CI確認）は `gh` CLIに依存するため、条件付きで有効化する。

```
Bridge起動時 / セッション開始時
├── `gh auth status` を実行
├── 結果をクライアントに通知
│
├── 認証済み → PR作成・Merge・CIステータスのUIを有効化
├── 未認証  → 「gh auth login を実行してください」の案内
└── 未インストール → Push までのUIに留める、PR系は非表示
```

- `bridge_service` の capabilities/ステータス通知に `ghCliStatus` を追加
- Phase 2 (Commit+Push) は `gh` 不要 → 全員が使える
- Phase 4 (PR操作) は `gh` 必須 → 条件付き表示

## AI補助（コミットメッセージ・PR生成）

コミットメッセージやPRタイトル/本文の自動生成にAIを利用する。
API直叩きではなく、CLIの正規インターフェース（`claude -p` / `codex -q`）で単発呼び出しする。

### 設計方針

- **規約遵守**: トークンを抜き出してAPI直叩きはしない。公式CLIの正規利用のみ
- **プロバイダー自動選択**: セッションがClaude Code / Codexのどちらかに応じてCLIを切り替え
- **ユーザーの課金プランに自然に乗る**: 追加の認証設定不要

### Codex Appとの比較

| | Codex App | ccpocket |
|---|---|---|
| 呼び出し方 | 内部API（ephemeralスレッド） | CLI正規インターフェース |
| モデル | `gpt-5.1-codex-mini` 固定 | 設定で変更可能 |
| 認証 | アプリ内蔵トークン | ホストマシンの既存CLI認証 |
| 規約 | 自社プロダクトなので自由 | 公式CLIの正規利用のみ |

### 呼び出しイメージ

```bash
# Claude Code セッションの場合
echo "${diff}" | claude -p --model claude-sonnet-4-6 \
  "Generate a commit message. ${customPrompt}"

# Codex セッションの場合
echo "${diff}" | codex -q --model gpt-5.4-mini \
  "Generate a commit message. ${customPrompt}"
```

### Bridge設定

現行実装では追加設定は持たず、アクティブなセッションの provider / model をそのまま使う。

- Claude セッションでは `SdkProcess.model` を優先
- Codex セッションでは `session.codexSettings.model` を優先
- model が取れない場合は CLI デフォルトにフォールバック

### 注意点

- CLI起動のオーバーヘッドがある（Codex Appのephemeralスレッドより遅い）
- コミットメッセージ程度なら許容範囲だが、頻繁に呼ぶと体感に影響
- 初回起動が遅い場合はスピナー表示で対応

## Bridge プロトコル

### Client → Server（新規追加分）

#### `git_stage` — ファイル/ハンクのステージング

```json
{
  "type": "git_stage",
  "projectPath": "/home/user/project",
  "files": ["lib/main.dart"],
  "hunks": [{ "file": "lib/app.dart", "hunkIndex": 0 }]
}
```

#### `git_unstage` — ステージング解除

```json
{
  "type": "git_unstage",
  "projectPath": "/home/user/project",
  "files": ["lib/main.dart"]
}
```

#### `git_commit` — コミット作成

```json
{
  "type": "git_commit",
  "projectPath": "/home/user/project",
  "sessionId": "s-1234",
  "message": "feat: add login screen",
  "autoGenerate": false
}
```

- `autoGenerate: true` のときのみ `sessionId` 必須
- `sessionId` に対応するアクティブセッションの provider で commit message を生成する
- `projectPath` はそのセッションの `worktreePath ?? projectPath` と一致している必要がある

#### `git_push` — リモートへpush

```json
{
  "type": "git_push",
  "projectPath": "/home/user/project"
}
```

#### `gh_pr_create` — PR作成

```json
{
  "type": "gh_pr_create",
  "projectPath": "/home/user/project",
  "title": "feat: add login screen",
  "body": "## Summary\n- Added login screen...",
  "draft": false,
  "autoGenerate": false
}
```

#### `gh_pr_status` — PRステータス取得

```json
{
  "type": "gh_pr_status",
  "projectPath": "/home/user/project"
}
```

#### `gh_pr_merge` — PRマージ

```json
{
  "type": "gh_pr_merge",
  "projectPath": "/home/user/project",
  "prNumber": 42,
  "method": "squash"
}
```

#### `git_branches` — ブランチ一覧取得

```json
{
  "type": "git_branches",
  "projectPath": "/home/user/project"
}
```

#### `git_create_branch` — ブランチ作成

```json
{
  "type": "git_create_branch",
  "projectPath": "/home/user/project",
  "name": "feat/login",
  "checkout": true
}
```

#### `git_checkout_branch` — ブランチ切替

```json
{
  "type": "git_checkout_branch",
  "projectPath": "/home/user/project",
  "branch": "feat/login"
}
```

### Server → Client（新規追加分）

#### `git_stage_result` / `git_unstage_result`

```json
{
  "type": "git_stage_result",
  "success": true
}
```

#### `git_commit_result`

```json
{
  "type": "git_commit_result",
  "success": true,
  "commitHash": "abc1234",
  "message": "feat: add login screen"
}
```

#### `git_push_result`

```json
{
  "type": "git_push_result",
  "success": true
}
```

#### `gh_pr_result`

```json
{
  "type": "gh_pr_result",
  "success": true,
  "prNumber": 42,
  "url": "https://github.com/user/repo/pull/42"
}
```

#### `gh_pr_status_result`

```json
{
  "type": "gh_pr_status_result",
  "prNumber": 42,
  "state": "open",
  "draft": false,
  "mergeable": true,
  "ciStatus": "success",
  "reviewStatus": "approved",
  "url": "https://github.com/user/repo/pull/42"
}
```

#### `git_branches_result`

```json
{
  "type": "git_branches_result",
  "current": "feat/login",
  "branches": ["main", "feat/login", "feat/signup"]
}
```

## 最小MVP（Phase 1 + 2の一部）

既存Diff Viewerに以下を追加するだけで最小限の価値が出せる:

1. **Staged/Unstaged タブ** — 既存のハンク選択をステージングに転用
2. **コミットボトムシート** — メッセージ入力 + Commitボタン
3. **Bridge側**: `git_stage`, `git_unstage`, `git_commit` メッセージ追加

これだけで「Codexセッション完了 → スマホでレビュー → コミット」がPCなしで完結する。

## Codex App 調査で判明した設計（参考）

### アーキテクチャ

Codex App（macOS）はElectron製デスクトップアプリ。エージェント（Rust製 `codex` バイナリ）ではなく、アプリ自身がGit操作を行う。

- Electron内にバックグラウンドの git worker (worker.js) が存在
- UIからのRPC呼び出しでgit操作を実行
- エージェントはコード変更を生成するだけ
- Git plumbing（ブランチ作成・コミット・プッシュ・PR作成）は全てアプリ側が担当

### Git Worker RPCメソッド（Mutating操作）

| メソッド | 説明 |
|---|---|
| `overwrite-repo` | リポジトリ内容の上書き |
| `git-init-repo` | gitリポジトリの初期化 |
| `create-worktree` | 新しいworktreeの作成 |
| `restore-worktree` | スナップショットからworktreeを復元 |
| `delete-worktree` | worktreeの削除 |
| `apply-changes` | パッチ/diff変更の適用 |
| `commit` | コミット作成 |
| `move-thread-to-local` | 会話のブランチをメインワーキングコピーに移動 |
| `move-thread-to-worktree` | 会話のブランチを専用worktreeに移動 |

### GUI画面別 Git操作

| 画面 | 主な操作 |
|------|---------|
| サイドバー | ブランチ・worktree単位のフィルタリング、永続worktree作成 |
| Composer内 `/` | Fork into local / worktree、ブランチ変更レビュー |
| Composerフッター | ブランチ検索・選択・新規作成 |
| Git Actionsツールバー | Branch here / Push / Create PR / Hand off |
| Diffパネル (`Cmd+D`) | Last turn / Branch タブ、ハンク単位Stage、Split/Unified diff |
| コミットフロー | メッセージ自動生成、Commit / Commit+Push / Commit+PR |
| PRパネル | ステータスバッジ、CI、Reviews、Merge、Fixボタン |
| Settings | Branch prefix、PR merge method、Commit/PR instructions |

### Sandbox下でのエージェント権限

| 区分 | コマンド例 | エージェントの権限 |
|---|---|---|
| 自動許可 | `git status`, `git log`, `git diff` | 実行可能 |
| 承認必要 | `git commit`, `git push`, `git checkout` | ユーザー承認が必要 |
| 危険フラグ | `git -c`, `--exec`, `--ext-diff` | ブロック対象 |

## 関連ファイル

| ファイル | 役割 |
|---------|------|
| `features/diff/` | 既存Diff Viewer |
| `utils/diff_parser.dart` | Unified diffパーサー |
| `services/bridge_service.dart` | WebSocketクライアント |
| `packages/bridge/src/websocket.ts` | メッセージハンドラ |
