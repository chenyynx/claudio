# Network Resilience Sync

## Context

CC Pocket はモバイル回線での利用が基本となる。地下鉄や移動中のように通信が不安定な環境でも、
セッションの状況把握と入力をできるだけ止めずに続けたい。

現状は Bridge が SSoT (single source of truth) であり、セッション画面に入るたびに
`get_history` で Bridge から履歴をフル取得して画面状態を復元している。この設計は整合性が高い一方で、
Active なセッションを頻繁に開き直すモバイル体験では通信量と待ち時間の負担になりやすい。

## 現状の主な制約

### セッション画面入場時のフル履歴取得

`ChatSessionCubit` は生成時に必ず `BridgeService.requestSessionHistory(sessionId)` を呼ぶ。

対象:

- `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart`
- `apps/mobile/lib/services/chat_message_handler.dart`
- `packages/bridge/src/websocket.ts`

Bridge 側の `get_history` は `past_history` と `session.history` をまとめて返す。クライアント側は
`HistoryMessage` を受けると `replaceEntries: true` で非 past 履歴を再構築する。

### 履歴差分を表す revision がない

Bridge の `SessionInfo.history` は `ServerMessage[]` で、単調増加する revision / sequence を持たない。
そのため「前回受信した seq 以降だけ取得する」ことができない。

対象:

- `packages/bridge/src/session.ts`
- `packages/bridge/src/parser.ts`
- `apps/mobile/lib/models/messages.dart`

### 未接続時の送信キューが汎用 FIFO

`BridgeService.send()` は未接続時に `_messageQueue` へ `ClientMessage` を積み、再接続後に flush する。
これは簡易的な再送としては有効だが、チャット入力専用ではない。

課題:

- `input`, `get_history`, `approve` などが同列に並ぶ
- 永続化されない
- `clientMessageId` がないため ack/reject とローカル入力を厳密に紐付けられない
- `baseSeq` がないため、別端末の入力が先に入った場合の衝突判定ができない

### Codex の Bridge 側 queue はオフライン予約ではない

Codex には busy 中の 1 件キュー (`conversation_queue`) がある。これはオンライン接続中に agent が
入力待ちでない場合の Bridge 側キューであり、モバイル端末がオフラインの間に予約する仕組みではない。

## 目指す UX

- セッション一覧や画面再入場で、最後に見えていた会話が即座に表示される
- 通信が戻ったら Bridge との差分だけを取得して自然に最新化される
- Running なセッションの status / approval / queued input は Bridge の状態に追従する
- オフライン中でも入力を予約できる
- 通信復帰時、Bridge が受理できる場合だけ送信される
- 別端末や別クライアントの user input が先に Bridge に入っていた場合、予約入力は失敗扱いにする
- 失敗時は入力内容を失わず、ユーザーが再送または編集できる

## 設計方針

### Bridge は引き続き SSoT

クライアントのキャッシュは表示高速化とオフライン下書きのために使う。最終的な履歴順序、
status、approval、queue は Bridge の状態を正とする。

App 側に保持する状態は「真の履歴」ではなく、Bridge の runtime projection として扱う。
この前提を崩さないため、App cache だけで履歴順序を確定したり、Bridge に未確認の入力を sent 扱いにしない。

### 互換性を保って段階導入する

既存の `get_history` は残す。新しい Bridge / App の組み合わせでは差分同期を使い、古い Bridge に接続した場合は
従来のフル履歴取得へフォールバックする。

Protocol v2 のような一括切り替えではなく、既存 protocol に optional field / optional message を足す。
これにより以下の組み合わせを許容する。

- 新 App + 旧 Bridge: `unsupported_message` を受けたら `get_history` / FIFO ack 処理へ fallback
- 旧 App + 新 Bridge: 既存 `get_history` / `input` を従来通り処理
- 新 App + 新 Bridge: `client_capabilities` に応じて delta sync / strict ack を有効化

互換性の基本ルール:

- `get_history` は削除しない
- `get_history_delta` は capability opt-in にする
- `input.clientMessageId` / `input.baseSeq` が無い場合も Bridge は従来通り受理する
- `input_ack.clientMessageId` が無い場合、App は従来の FIFO 更新へ fallback する
- 新しい `ServerMessage` は App 側で unknown/unsupported を安全に無視できる形にする

### 差分同期とオフライン送信を分けて実装する

まず「再入場時のフル取得を減らす」。その後に `clientMessageId` / `baseSeq` を導入して
オフライン予約と衝突判定を実装する。

### 複数 Running セッションを前提にする

複数の Running セッションが同時に存在するため、セッションごとの runtime state を個別の `Map` に増やし続けると
取り違えや移行漏れが起きやすい。既存でも Explorer 履歴は `BridgeService` 内にセッション別で保持されているため、
timeline cache を追加するタイミングで統合管理基盤へ寄せる。

初期案:

```dart
class SessionRuntimeState {
  final String sessionId;
  final List<TimelineEntry> timeline;
  final int? lastSeq;
  final ProcessStatus status;
  final QueuedInputItem? queuedInput;
  final PermissionRequestMessage? pendingPermission;
  final ExplorerHistorySnapshot explorerHistory;
  final List<PendingOfflineAction> pendingOfflineActions;
}
```

この基盤は Bridge の投影状態であり、Bridge からの snapshot / delta / status / queue / permission を適用して更新する。
session switch / rewind / sandbox restart で `sessionId` が変わる場合は、draft と同様に runtime state も移行対象にする。

## Phase 1: アプリ側 timeline cache

目的: 画面を閉じても直前の会話をアプリ内に保持し、再入場を即時表示にする。

### 変更概要

- `BridgeService` 配下に `SessionRuntimeStore` を追加する
- 既存の Explorer 履歴 (`_explorerHistoryBySession`) を `SessionRuntimeStore` へ移す
- `SessionRuntimeStore` にセッション別 timeline cache を持つ
- `messagesForSession(sessionId)` で受けた live message を cache に反映する
- `ChatSessionCubit` 生成時に cache snapshot を初期状態として渡す
- その後、従来通り `get_history` で Bridge と整合する

### 新規候補

- `apps/mobile/lib/services/session_runtime_store.dart`
- `apps/mobile/test/session_runtime_store_test.dart`

### 成果

- 画面再入場直後に空画面や spinner になりにくい
- Bridge プロトコル変更なしで UX を改善できる
- 以降の差分同期の受け皿を作れる
- Explorer 履歴、timeline、将来の offline pending actions を同じ session runtime 管理へ寄せられる

### 注意点

この段階では通信量削減は限定的。最終整合のため `get_history` フル取得はまだ行う。

Phase 1 では統合しすぎない。まず Explorer 履歴と timeline cache だけを `SessionRuntimeStore` に載せ、
diff image cache や offline pending actions は後続 Phase で移す。

## Phase 2: Bridge 履歴 revision と delta API

目的: セッション画面入場時に、前回受信後の差分だけで最新化できるようにする。

### Bridge 側

`SessionInfo` に revision を追加する。

```ts
interface SessionInfo {
  history: ServerMessage[];
  historyRevision: number;
  historyLowWatermark: number;
}
```

履歴に追加するたびに `historyRevision` を increment し、各メッセージに `seq` を付けて管理する。
既存の `ServerMessage` 型を大きく壊さないため、内部的には envelope を持つ案を優先する。

```ts
interface HistoryEntry {
  seq: number;
  timestamp: string;
  message: ServerMessage;
}
```

### Protocol

Client → Server:

```json
{
  "type": "get_history_delta",
  "sessionId": "abcd1234",
  "sinceSeq": 42
}
```

Server → Client:

```json
{
  "type": "history_delta",
  "sessionId": "abcd1234",
  "fromSeq": 43,
  "toSeq": 51,
  "messages": [
    { "seq": 43, "message": { "type": "status", "status": "running" } }
  ],
  "status": "running"
}
```

`sinceSeq < historyLowWatermark` の場合は差分を返せないため snapshot にフォールバックする。

```json
{
  "type": "history_snapshot",
  "sessionId": "abcd1234",
  "fromSeq": 12,
  "toSeq": 51,
  "messages": []
}
```

### App 側

- `ClientMessage.getHistoryDelta(sessionId, sinceSeq)` を追加
- `HistoryDeltaMessage` / `HistorySnapshotMessage` を追加
- timeline cache が `lastSeq` を保持する
- `ChatSessionCubit` は cache を即描画し、delta 適用で最新化する
- 古い Bridge で `unsupported_message` が返った場合は `get_history` にフォールバックする

### 成果

- Active セッション再入場時の通信量を大きく削減できる
- status / approval / queue の復元も差分で扱える

## Phase 3: ack の厳密化

目的: 入力と ack/reject を `clientMessageId` で対応付け、複数 pending や再送に耐える。

### Protocol

Client → Server:

```json
{
  "type": "input",
  "sessionId": "abcd1234",
  "clientMessageId": "client-uuid",
  "baseSeq": 51,
  "text": "続きを実装して"
}
```

Server → Client:

```json
{
  "type": "input_ack",
  "sessionId": "abcd1234",
  "clientMessageId": "client-uuid",
  "acceptedSeq": 52,
  "queued": false
}
```

```json
{
  "type": "input_rejected",
  "sessionId": "abcd1234",
  "clientMessageId": "client-uuid",
  "reason": "conflict"
}
```

### 変更概要

- `ClientMessage.input` に `clientMessageId` と `baseSeq` を追加
- Bridge は `clientMessageId` を ack/reject に含める
- App は FIFO ではなく ID で該当する `UserChatEntry` を更新する
- 既存 Bridge では `clientMessageId` なし ack が返るため、従来の FIFO 更新を fallback として残す

### 互換性

`clientMessageId` / `baseSeq` は optional とする。Bridge は両方がある場合だけ strict validation を行う。
片方でも無い場合は従来動作にする。

## Phase 4: offline pending actions

目的: オフライン中のユーザー操作を安全な範囲で予約し、通信復帰時に Bridge の状態と照合して送信する。

初期対象は以下の5系統に絞る。

1. `input`
2. `start session`
3. `resume session`
4. `rename session`
5. `Codex queued input` の update / cancel

### App 側データ

```dart
sealed class PendingOfflineAction {
  final String actionId;
  final DateTime createdAt;
}

class PendingInputAction extends PendingOfflineAction {
  final String sessionId;
  final String clientMessageId;
  final int baseSeq;
  final String text;
  final List<PendingImage> images;
}

class PendingStartSessionAction extends PendingOfflineAction {
  final String tempSessionId;
  final String projectPath;
  final Provider provider;
  final Map<String, dynamic> startOptions;
}

class PendingResumeSessionAction extends PendingOfflineAction {
  final String providerSessionId;
  final String projectPath;
  final Provider provider;
  final Map<String, dynamic> resumeOptions;
}

class PendingRenameSessionAction extends PendingOfflineAction {
  final String sessionId;
  final String? providerSessionId;
  final String? projectPath;
  final String name;
}

class PendingCodexQueueAction extends PendingOfflineAction {
  final String sessionId;
  final String itemId;
  final CodexQueueActionKind kind; // update or cancel
  final String? text;
}
```

保存先候補:

- まずは `SharedPreferences` または既存の `DraftService` 周辺
- 画像添付を扱う場合はサイズが大きいため、ファイル保存 + metadata 保存に分ける
- temp session を表示するため、`SessionRuntimeStore` に pending session state を持たせる

### input の再接続時の流れ

1. `get_history_delta(sessionId, sinceSeq: baseSeq)` を送る
2. 返ってきた差分を timeline cache に適用する
3. 差分内に他端末由来の `user_input` があるか確認する
4. なければ `input(clientMessageId, baseSeq)` を送る
5. あれば pending input を `failed_conflict` にする

Bridge 側でも `baseSeq` を検証し、現在 revision と合わない場合は `input_rejected(reason: "conflict")` を返す。
クライアント側の事前判定は UX のためであり、最終判定は Bridge が行う。

### start session の再接続時の流れ

オフライン中に新規セッション作成を予約する。App は `tempSessionId` を持つ pending session を表示し、
復帰後に Bridge へ `start` を送る。

1. オフライン中に `PendingStartSessionAction` を作成する
2. セッション一覧に pending session を表示する
3. 復帰後、projectPath / provider / startOptions を検証して `start` を送る
4. `session_created` を受けたら `tempSessionId` から実 sessionId へ runtime state / draft を移行する
5. 失敗したら pending session に error を表示し、再試行または削除できるようにする

この action は Bridge 上にはまだ存在しないため、Bridge SSoT と矛盾しないように pending 表示であることを明確にする。

### resume session の再接続時の流れ

オフライン中に過去セッションの resume を予約する。復帰時に active session / recent history を再確認し、
対象 provider session が別端末で進んでいる可能性がある場合は自動 resume せず失敗扱いにする。

1. `PendingResumeSessionAction` を作成する
2. 復帰後、session list / recent sessions を更新する
3. 対象 provider session の modified timestamp / summary / known revision 相当を確認する
4. 変化がなければ `resume_session` を送る
5. 変化があれば `failed_conflict` とし、ユーザーに再同期後の resume を促す

resume は会話の前提を再読み込みする操作なので、input より保守的に扱う。

### rename session の再接続時の流れ

rename は低リスクな metadata 更新として扱う。基本は latest-wins でよいが、対象 session が存在しない場合は失敗にする。

1. `PendingRenameSessionAction` を保存する
2. 復帰後、sessionId または providerSessionId が解決できるか確認する
3. 解決できれば `rename_session` を送る
4. 解決できなければ failed にする

### Codex queued input update / cancel の再接続時の流れ

Bridge 側 queue は SSoT なので、復帰時点で `itemId` がまだ存在する場合だけ適用する。

1. `get_history_delta` または `get_history` fallback で `conversation_queue` を取得する
2. `itemId` が一致する queue item があれば update / cancel を送る
3. queue item が無ければ failed にする

### 対象外にする action

初期実装では以下を offline pending 対象にしない。

- `approve` / `reject` / `answer`: 時間依存が強く、安全な自動適用が難しい
- `stop_session` / `interrupt`: 復帰時には対象 turn が終わっている可能性が高い
- git 操作: working tree が変わりやすく、conflict 判定が重い
- file / diff / gallery / screenshot などの読み取り系: pending ではなく cache または retry で扱う
- rewind / sandbox restart / worktree 操作: セッション前提を変えるため、オフライン予約と相性が悪い

### UI

- 送信ボタン押下時、未接続なら `scheduled` 状態のユーザーバブルを表示
- 再接続後、送信中は `sending`
- Bridge が受理したら `sent`
- 衝突したら `failed` にし、説明テキストと「編集して再送」を出す
- start/resume は pending session card として表示する
- rename / Codex queue action は対象 UI の近くに小さく pending 表示する

## Phase 5: ネットワーク品質 UX

目的: 不安定回線でもユーザーが状態を理解できるようにする。

### UI 候補

- セッション画面上部の reconnect banner に「最終同期時刻」を表示
- offline pending action がある場合は composer または session card 近くに小さく件数表示
- conflict 時は通常のエラーではなく、入力バブル単位で復旧導線を出す
- `waiting_approval` 中にオフラインになった場合は approval 操作を無効化し、復帰後に最新状態を再確認する

### 方針

通信状態を大きな警告として出し続けるより、現在の操作に必要な情報だけを局所的に表示する。

## 衝突判定ルール

初期実装では保守的にする。

`baseSeq` 以降に以下がある場合、`PendingInputAction` は conflict とする。

- 他端末または別クライアント由来の `user_input`
- `result` による turn 完了
- session switch / rewind / sandbox restart など、会話の前提が変わる system event
- `stop_session`

以下は conflict としない。

- `status`
- `stream_delta` / `thinking_delta` (履歴 revision 対象外でもよい)
- `assistant`
- `tool_result`
- `permission_request`
- `permission_resolved`
- `conversation_queue`

このルールは「同じ会話ターンにユーザー入力が割り込む」ことだけを避ける設計にする。

`PendingStartSessionAction` は Bridge 上にまだ存在しないため、projectPath / provider / startOptions が有効なら conflict ではなく実行する。

`PendingResumeSessionAction` は provider session の modified timestamp / known metadata が変化していたら conflict とする。

`PendingRenameSessionAction` は対象 session が解決できなければ failed、解決できれば latest-wins とする。

`PendingCodexQueueAction` は対象 `itemId` が Bridge queue に存在しなければ failed とする。

## 検証計画

テストファーストで進める。E2E で全仕様を担保しようとせず、Bridge / pure Dart の単体テストで
プロトコルと状態遷移を固定し、E2E は代表的なユーザー体験に絞る。

### Bridge

- `get_history_delta` が `sinceSeq` 以降だけ返す
- `sinceSeq` が古すぎる場合に `history_snapshot` へフォールバックする
- `input` が `clientMessageId` を ack/reject に含める
- `baseSeq` 不一致で conflict reject する
- 既存 `get_history` が従来通り動く
- `clientMessageId` / `baseSeq` なしの input が従来通り受理される
- 複数 Running セッションで revision / queue / status が混ざらない

### Flutter unit/widget

- `SessionRuntimeStore` が sessionId ごとに timeline / explorerHistory / status を分離する
- session switch 時に runtime state を移行できる
- timeline cache から即時表示される
- `history_delta` 適用で重複しない
- `history_snapshot` で cache が置き換わる
- `clientMessageId` 付き ack/reject で正しいバブルだけ状態更新される
- `clientMessageId` なし ack では FIFO fallback が動く
- offline pending actions が再接続後に action 種別ごとの validation を通って送信される
- conflict 時に入力内容が失われない
- start session の pending card が `session_created` 後に実 session へ移行される
- resume session が metadata 変化時に conflict になる
- Codex queue update/cancel が `itemId` 消失時に failed になる

### E2E

- 通信切断中にセッション画面を開き直しても cached timeline が表示される
- Running セッションに戻ったとき delta だけで最新化される
- オフライン入力 → 復帰 → Bridge 受理
- オフライン入力 → 別端末入力 → 復帰 → conflict
- オフライン新規セッション作成 → 復帰 → session_created で temp session から移行
- オフライン resume → 復帰 → metadata 変化なしなら resume
- 古い Bridge に接続した場合、フル履歴取得 fallback で利用継続できる

## 実装順まとめ

1. `SessionRuntimeStore` を導入し、Explorer 履歴と timeline cache を統合する
2. Bridge history revision と `get_history_delta` を追加する
3. App を delta/snapshot 対応にし、古い Bridge への fallback を入れる
4. `clientMessageId` / `baseSeq` 付き input と ack/reject を追加する
5. offline pending actions の永続化と再接続 flush を実装する
6. conflict / scheduled / last synced などの UX を整える

## 未決事項

- `SessionRuntimeStore` をメモリのみから始めるか、アプリ再起動を跨いで永続化するか
- 画像付き pending input action の保存方式
- `historyRevision` に status-only event を含めるか
- `stream_delta` を差分同期対象に含めるか
- Claude / Codex で conflict 判定を同一にするか、Codex queue を優先して別ルールにするか
- diff image cache も `SessionRuntimeStore` に統合するか、別 cache として残すか
- pending start/resume session をアプリ再起動後も復元するか
- resume conflict 判定に使う provider session metadata をどこまで保持するか
