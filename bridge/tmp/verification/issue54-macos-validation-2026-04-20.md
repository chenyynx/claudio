# Issue #54 macOS validation - 2026-04-20

## Scope

- Verify Git diff path handling for non-ASCII and space-containing paths on the macOS app.
- Verify Codex reasoning effort behavior with app-driven and raw WebSocket starts.

## Environment

- Date: 2026-04-20
- Host: macOS
- App target: `apps/mobile` on `macos`
- Test Bridge: `ws://127.0.0.1:8766`

## Prepared validation data

- Repo fixture root: `tmp/verification/issue54-path`
- Modified files:
  - `tmp/verification/issue54-path/docs/あいう.md`
  - `tmp/verification/issue54-path/docs/空 白.md`
- Raw git diff fixtures:
  - `tmp/verification/issue54-git-diff.txt`
  - `tmp/verification/issue54-git-diff-quoted.txt`

## App-driven verification

### Codex session start on macOS

- Opened the new session sheet in the macOS app.
- Switched provider to `Codex`.
- Confirmed the sheet model summary showed:
  - model: `gpt-5.4`
  - reasoning effort: `High`
- Started a session for `tmp/verification/issue54-path`.
- Confirmed the created session card and session pane both displayed `gpt-5.4 High`.

### Git diff rendering

- Opened the Changes pane for the `issue54-path` session.
- Confirmed file headers rendered as:
  - `docs/あいう.md`
  - `docs/空 白.md`
- Confirmed hunk rows rendered normally for both files.
- Confirmed no quoted path form like `\"docs/...\"` or escaped octal path was shown in the UI.

### Git staging

- Executed `Stage All` from the Changes pane.
- Confirmed the action row changed from `Stage All` to `Unstage All / Commit`.
- Confirmed no runtime error was reported by Dart tooling during staging.

## Raw WebSocket verification

### Artifacts

- `tmp/verification/issue54-xhigh-ws-messages.json`
- `tmp/verification/issue54-xhigh-runtime-messages.json`
- `tmp/verification/issue54-xhigh-runtime-after-fix.json`

### Observations

- The start payload used `modelReasoningEffort: "xhigh"`.
- Bridge `session_created` echoed `modelReasoningEffort: "xhigh"`.
- `session_list.sessions[].codexSettings.modelReasoningEffort` also stayed `xhigh`.
- In the runtime transcript, the later `system.init` message reported `modelReasoningEffort: "high"`.

### After Bridge fix

- Rebuilt Bridge and restarted it on:
  - `ws://127.0.0.1:8768`
  - then `ws://127.0.0.1:8766` for app compatibility
- Re-ran raw WebSocket verification against the updated Bridge.
- Confirmed `system.init` now reports:
  - `modelReasoningEffort: "xhigh"`
- Confirmed `session_created` and `session_list.codexSettings` still report:
  - `modelReasoningEffort: "xhigh"`

## Interpretation

- Git path handling is verified end-to-end on macOS for:
  - non-ASCII file names
  - space-containing file names
  - diff display
  - stage-all flow
- `High` is verified in the actual app UI.
- `xhigh` is preserved through Bridge session creation and session list state.
- Before the fix, `xhigh` was not preserved in the observed `system.init` message and appeared downgraded to `high` at runtime.
- After the fix, `xhigh` is preserved in the Bridge-emitted `system.init` message as well.

## Notes

- Marionette could not reliably tap `dialog_codex_reasoning_effort` inside the macOS new-session sheet, so `xhigh` was validated through raw Bridge traffic instead of direct dropdown selection in the app UI.
- App logs showed prior Marionette probing errors during the session-sheet investigation, but `get_runtime_errors` stayed clean during the actual diff/staging verification.
