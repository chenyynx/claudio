# Prompt History 2.0

## Summary

Prompt History 2.0 moves prompt history ownership from each mobile device to the
Bridge. The Bridge is the single source of truth, and the app-side SQLite data is
a cache used for fast display, offline browsing, and migration from the 1.0 local
table.

The 1.0 table is retained. Migration is explicit and overwrite-only: when the
app and current Bridge support 2.0, the settings screen can initialize the
current Bridge's 2.0 history from this device's 1.0 history. This keeps the
logic simple and assumes the user performs migration from their main device;
secondary devices' 1.0-only history is intentionally not merged.

## Data Model

Bridge stores prompt history in a JSON file scoped to the Bridge instance:

- default port `8765`: `~/.ccpocket/prompt-history-v2.json`
- non-default ports: `~/.ccpocket/prompt-history-v2-<port>.json`
- override escape hatch: `BRIDGE_PROMPT_HISTORY_FILE=/path/to/file.json`

This keeps multiple Bridges on the same PC independent. The app cache is also
keyed by the Bridge-provided `bridgeInstanceId`, not by connection URL. This
means `localhost:8765`, a LAN IP, and a Tailscale IP that point to the same
running Bridge are treated as aliases of one Bridge and do not double-count.
The app merges multiple Bridge caches only for display.

The JSON contains:

- `version: 2`
- monotonic `revision`
- `entries[]`

Each entry uses a stable id derived from `projectPath + text` and contains:

- `id`, `text`, `projectPath`
- `totalUseCount`, `isFavorite`
- `createdAt`, `lastUsedAt`, `updatedAt`
- `favoriteUpdatedAt`, `deletedAt`
- `commandKind: none | slash | skill`
- `clientStats[clientId] = { useCount, lastUsedAt, clientName }`
- `sessionStats[sessionId] = { useCount, lastUsedAt }`

Deleted prompts remain as tombstones so deletes can be synchronized to clients.

## Protocol

Client to Bridge:

- `record_prompt_history`: record a sent prompt for a client/session.
- `sync_prompt_history`: fetch the Bridge snapshot, optionally after sending
  client-side entries.
- `mutate_prompt_history`: favorite, delete, or restore an entry.
- `import_prompt_history_v1`: replace the Bridge history from the old app-local
  history during 1.0 migration.

Bridge to client:

- `prompt_history_sync_result` with `bridgeInstanceId`
- `prompt_history_mutation_result`
- `prompt_history_status` with `bridgeInstanceId`

Old Bridges return `unsupported_message`; the app keeps using the 1.0 local
table and shows an update hint for user-triggered mutation/import operations.

The old app-database backup protocol (`backup_prompt_history`,
`restore_prompt_history`, and `get_prompt_history_backup_info`) is retained on
the Bridge for old clients only. The 2.0 app no longer exposes those controls.

## App Behavior

The app syncs prompt history:

- when a Bridge connection is established
- when the history sheet opens
- when the settings status section is opened or manually refreshed

Saved online Bridges are synced with short-lived WebSocket connections. The app
does not synchronize Bridges with each other; it merges cached rows from multiple
Bridges for display.

Merge display rules:

- Same stable id is shown once.
- Use counts are summed.
- Favorite is true if any synced Bridge marks the entry favorite.
- Last-used time is the max timestamp.
- Filters are applied as AND conditions.

## UI

Settings shows:

- sync status per Bridge
- manual sync
- overwrite-only 1.0 migration from this device
- no 1.0 backup/restore controls; old app-database backup is retired from the
  UI because the Bridge is now the source of truth

The prompt history sheet removes full-text search and project chips. It uses:

- a single cycling sort button: frequent -> recent -> favorite-first
- an animated filter header menu with:
  - this device
  - this project
  - this Bridge
  - favorites
  - slash/skill prompts (`/` or `$`)

## Verification

Bridge verification:

- `PromptHistoryStore` unit tests for stable ids, merge, tombstones, import.
- parser tests for new message types.
- `npm run test:bridge`
- `npx tsc --noEmit -p packages/bridge/tsconfig.json`

Flutter verification:

- cache/sync/filter unit tests.
- widget tests for history sheet and settings section.
- `dart analyze apps/mobile`
- `dart format apps/mobile`
- `cd apps/mobile && flutter test`

E2E verification:

- run a test Bridge on `BRIDGE_PORT=8766`
- launch the app with Marionette
- verify migration card, manual sync, filter chips, sort cycling, and old-Bridge
  fallback behavior.
