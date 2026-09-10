/**
 * Claude model list assembly for the remote bridge.
 *
 * Why this module exists (2026-09-11): the bridge advertises its available
 * Claude models to the iOS app via `session_list.claudeModels`, and the app's
 * model picker renders exactly that list. Two sources feed it:
 *   1. the SDK's `supportedModels()` (authoritative when it answers), and
 *   2. a static Anthropic fallback used when it does not.
 * Neither knows about a provider switch done at the host level (pp's `sm`, which
 * rewrites ANTHROPIC_MODEL in ~/.claude/settings.json and the bridge's pm2 env).
 * The bridge process had been up since 09-09, so its in-memory list still showed
 * the pre-switch provider's models — the app offered only those, and picking one
 * made the endpoint answer 400.
 *
 * The fix is deliberately limited to the ADVERTISED list: models the current
 * environment actually serves come first, so the picker always offers something
 * the endpoint accepts. How a client-requested model is passed to the SDK is
 * untouched — that pass-through is upstream behaviour and stays as it is.
 * @module claude-model-list
 */

import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Host settings file (Claude Code). `sm` (~/bin/switch-model) rewrites its `env`
 * block on every provider switch and does NOT touch pm2 — so a long-running
 * bridge's process.env is a stale snapshot. Reading the file on demand (cached
 * by mtime+size) is what makes a provider switch take effect with zero restarts.
 * Precedence mirrors Claude Code itself: the settings.json env block beats the
 * inherited shell environment.
 */
function settingsPath(): string {
  return process.env["CLAUDIO_SETTINGS_PATH"] ?? join(homedir(), ".claude", "settings.json");
}

let hostCache: { readonly key: string; readonly env: Readonly<Record<string, string>> } | undefined;

/** The settings.json env block, re-read only when the file actually changed. */
export function hostEnvBlock(path = settingsPath()): Readonly<Record<string, string>> {
  let stat;
  try {
    stat = statSync(path);
  } catch {
    hostCache = undefined; // gone/unreadable: nothing to remember
    return {};
  }
  // path belongs in the key: two files of identical size/mtime must never share a cache entry
  const key = `${path}:${stat.mtimeMs}:${stat.size}`;
  if (hostCache !== undefined && hostCache.key === key) return hostCache.env;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { env?: Record<string, unknown> };
    const raw = parsed.env;
    const collected: Record<string, string> = {};
    if (raw !== undefined && raw !== null && typeof raw === "object") {
      for (const [name, value] of Object.entries(raw)) {
        if (typeof value === "string") collected[name] = value;
      }
    }
    hostCache = { key, env: collected };
    return collected;
  } catch {
    // corrupt JSON mid-write must not break the bridge: fall back to the
    // inherited environment, and do not poison the cache with a bad read
    return {};
  }
}

/** The environment as the host currently declares it: process env + settings.json wins. */
export function effectiveEnv(): NodeJS.ProcessEnv {
  return { ...process.env, ...hostEnvBlock() };
}

/** Environment variables that name a model the current provider serves. */
const MODEL_ENV_KEYS = [
  "ANTHROPIC_MODEL",
  "ANTHROPIC_DEFAULT_OPUS_MODEL",
  "ANTHROPIC_DEFAULT_SONNET_MODEL",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  "CLAUDE_CODE_SUBAGENT_MODEL",
] as const;

/**
 * Models named by the environment, in declaration order, de-duplicated.
 * Blank/unset entries are skipped; a provider that declares nothing yields [].
 */
export function envConfiguredModels(env?: NodeJS.ProcessEnv): string[] {
  // no explicit env passed → ask the host, hot (this is what a provider switch
  // without a restart depends on)
  const source = env ?? effectiveEnv();
  const seen = new Set<string>();
  const models: string[] = [];
  for (const key of MODEL_ENV_KEYS) {
    const raw = source[key];
    if (typeof raw !== "string") continue;
    const model = raw.trim();
    if (model === "" || seen.has(model)) continue;
    seen.add(model);
    models.push(model);
  }
  return models;
}

/**
 * Put the environment's models first, then whatever else was discovered.
 * Order matters: the app renders the list as-is, so the first entries are the
 * ones a user sees and picks by default.
 */
export function withEnvModels(
  discovered: readonly string[],
  env?: NodeJS.ProcessEnv,
): string[] {
  const envModels = envConfiguredModels(env);
  const seen = new Set(envModels);
  const rest = discovered.filter((model) => {
    if (seen.has(model)) return false;
    seen.add(model);
    return true;
  });
  return [...envModels, ...rest];
}

/**
 * Pick the model to actually run for one request.
 *
 * pp's decision (2026-09-11): a stored session model can outlive the provider it
 * was chosen for (host `sm` switches rewrite the environment; the app keeps
 * sending whatever it has saved). Passing that name through 400s every turn, and
 * the server has no way to correct the app's stored value — so fall back to the
 * model the environment declares, and say so in the log.
 *
 * Deliberately conservative:
 *  - a legal request is returned untouched (upstream pass-through stays intact),
 *  - an empty/absent request is left alone (the SDK's own default applies),
 *  - with no environment-declared fallback we change nothing: guessing would
 *    silently override the user's choice, which is worse than an honest 400.
 */
export function resolveAllowedModel(
  requested: string | undefined,
  allowed: readonly string[],
  fallback: string | undefined,
): { model: string | undefined; fellBackFrom?: string } {
  if (requested === undefined || requested.trim() === "") return { model: requested };
  if (allowed.includes(requested)) return { model: requested };
  if (fallback !== undefined && fallback.trim() !== "") {
    return { model: fallback, fellBackFrom: requested };
  }
  return { model: requested };
}
