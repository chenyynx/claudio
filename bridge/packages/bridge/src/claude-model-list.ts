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
export function envConfiguredModels(env: NodeJS.ProcessEnv = process.env): string[] {
  const seen = new Set<string>();
  const models: string[] = [];
  for (const key of MODEL_ENV_KEYS) {
    const raw = env[key];
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
  env: NodeJS.ProcessEnv = process.env,
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
