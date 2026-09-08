# Issue #54 xhigh investigation - 2026-04-20

## Conclusion

The raw `codex app-server` response changes depending on the global Codex configuration state.

- Before removing the global effort setting:
  - `thread/start` with `effort: "xhigh"` returned `reasoningEffort: "high"`
- After removing the global effort setting:
  - `thread/start` with `effort: "high"` returned `reasoningEffort: null`
  - `thread/start` with `effort: "xhigh"` also returned `reasoningEffort: null`

This means the observed Bridge behavior is still downstream of upstream response behavior. The Bridge is not inventing `high`; it is reflecting or falling back based on what app-server returns.

## Probe artifacts

- Probe script: `tmp/verification/codex-app-server-effort-probe.mjs`
- Probe output: `tmp/verification/codex-app-server-effort-probe-output.json`

## Probe method

The probe bypasses Flutter and Bridge WebSocket routing and talks to:

- `codex app-server --listen stdio://`

Sequence used for each effort value:

1. `initialize`
2. `initialized` notification
3. `thread/start`

Compared requests:

- `effort: "high"`
- `effort: "xhigh"`

Both requests used:

- `model: "gpt-5.4"`
- `approvalPolicy: "on-request"`
- `sandbox: "workspace-write"`

## Key observation

### Request

The `xhigh` request was sent as:

```json
{
  "method": "thread/start",
  "params": {
    "effort": "xhigh",
    "model": "gpt-5.4"
  }
}
```

### Response

The direct app-server response still returned:

```json
{
  "result": {
    "model": "gpt-5.4",
    "reasoningEffort": "high"
  }
}
```

This matched the Bridge-observed downgrade before the global config change.

## Re-run after removing global effort setting

The same direct probe was rerun after removing the global Codex effort setting.

Observed summary:

```json
[
  {
    "effort": "high",
    "responseReasoningEffort": null
  },
  {
    "effort": "xhigh",
    "responseReasoningEffort": null
  }
]
```

So the current upstream behavior is:

- no stable `xhigh` echo
- no stable distinction between requested `high` and `xhigh`
- `reasoningEffort` may be omitted/null depending on external config state

## Recommended next steps

1. Decide desired product behavior.
2. If the app should display the requested value, preserve both:
   - requested effort
   - resolved/runtime effort
3. If the app should display actual runtime behavior, treat upstream `reasoningEffort` as optional and do not assume it will always be present.
4. If this is considered a provider bug, report upstream with:
   - the raw `thread/start` request
   - the raw `thread/start` response
   - model `gpt-5.4`
   - effort `xhigh`
   - note that removing the global effort config changes the response from `"high"` to `null`

## Notes

The probe required running outside the sandbox because Codex needs access to:

- `/Users/k9i-mini/.codex/sessions`
