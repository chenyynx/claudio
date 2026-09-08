# Codex app-server Migration (Bridge)

## Goal

Enable real approval flow for Codex sessions in ccpocket by migrating from `@openai/codex-sdk` stream handling to `codex app-server` JSON-RPC.

## Scope

- Bridge server only (`packages/bridge`)
- Keep existing mobile WS protocol (`permission_request`, `approve`, `reject`) compatible
- No behavioral change for Claude sessions

## Design Decisions

1. Transport: `stdio://` via `codex app-server --listen stdio://`
2. Runtime wiring: keep `SessionManager` / `BridgeWebSocketServer` APIs stable
3. Approval mapping:
   - server request `item/commandExecution/requestApproval` -> WS `permission_request` (`toolName: Bash`)
   - server request `item/fileChange/requestApproval` -> WS `permission_request` (`toolName: FileChange`)
   - WS `approve`/`approve_always`/`reject` -> JSON-RPC response `{decision: accept|decline}`
4. Keep Codex start options parity where possible:
   - `approvalPolicy`, `sandboxMode`, `model`, `modelReasoningEffort`

## Implemented

- Replaced `packages/bridge/src/codex-process.ts` with app-server based process:
  - initialize handshake (`initialize` / `initialized`)
  - `thread/start` / `thread/resume`
  - `turn/start` / `turn/interrupt`
  - JSON-RPC request/response routing
  - approval request handling and pending state management
  - status propagation (`idle` / `running` / `waiting_approval`)
  - conversion from app-server item notifications to bridge `ServerMessage`
- Updated `packages/bridge/src/websocket.ts`:
  - Codex sessions now accept `approve`, `approve_always`, `reject`
- Updated `packages/bridge/src/session.ts`:
  - pending permission summary now works for both Claude and Codex processes
- Added/updated tests:
  - `packages/bridge/src/codex-process.test.ts`
  - `packages/bridge/src/websocket.test.ts` (expectation fix)

## Validation

Executed:

- `npx tsc --noEmit -p packages/bridge/tsconfig.json`
- `cd packages/bridge && npx vitest run src/codex-process.test.ts src/session.test.ts src/websocket.test.ts`

Result: passed.

Additional full-suite run:

- `cd packages/bridge && npx vitest run`

Result: one unrelated existing failure in `src/version.test.ts` (expected version mismatch).

## Latest Catch-up (2026-03-19)

- Local Codex clone updated to `openai/codex@903660edb` (`main`)
- `app-server-protocol` now exposes a broader v2 request/notification surface than the bridge currently consumes

### Protocol deltas relevant to ccpocket

1. Approval response shapes changed
   - Command/file approvals now use `decision: "acceptForSession"` instead of the older `acceptSettings.forSession` style.
   - Command approvals may also offer `availableDecisions`, `proposedExecpolicyAmendment`, and `proposedNetworkPolicyAmendments`.
2. New server requests were added
   - `item/permissions/requestApproval`
   - `mcpServer/elicitation/request`
   - `item/tool/call` (experimental)
3. New lifecycle notifications were added
   - `serverRequest/resolved`
   - `hook/started`, `hook/completed`
   - `item/autoApprovalReview/*`
   - `account/updated`, `account/rateLimits/updated`
   - realtime notifications under `thread/realtime/*`
4. Thread bootstrap contract expanded
   - `thread/start` / `thread/resume` support `persistExtendedHistory`
   - `thread/start` requires `experimentalRawEvents` and `persistExtendedHistory` in the generated v2 schema
5. Approval policy surface expanded
   - `AskForApproval` now includes granular policy flags such as `request_permissions` and `mcp_elicitations`

### Current bridge gaps

- `packages/bridge/src/codex-process.ts` now also handles:
  - `item/permissions/requestApproval`
  - `mcpServer/elicitation/request`
  - `serverRequest/resolved`
- `approveAlways()` now emits latest `decision: "acceptForSession"` for command/file approvals.
- Thread bootstrap now opts into `persistExtendedHistory`.
- Remaining gaps:
  - `item/tool/call` / `dynamicToolCall` is normalized into tool history, but there is still no dedicated mobile affordance beyond generic tool-use/result rendering.
  - Permission UI now surfaces amendment summaries, but still does not offer dedicated controls for choosing among protocol-level policy amendment variants.
  - Codex-only recent sessions now prefer `thread/list`, but mixed/all-provider recent session loading still depends on rollout scanning instead of a unified app-server-backed index.

### Recommended next implementation slice

1. Decide whether dynamic tools need dedicated mobile UI instead of the current generic tool history rendering.
2. Decide whether ccpocket wants interactive controls for granular approval policy amendments instead of summary-only display.
3. Decide whether all-provider recent-session fetching should move off rollout scanning.
4. Add real Codex E2E coverage for permissions + elicitation flows on mobile.

## Follow-ups

1. Add optional backend flag (`CODEX_BACKEND=sdk|app-server`) if rollback path is required.
2. Add E2E scenario with a real Codex session and actual approval UI interaction on mobile.
3. Verify optional app-server fields (`webSearchMode`, network policy, `persistExtendedHistory`) against pinned Codex CLI version in production.
