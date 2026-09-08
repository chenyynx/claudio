import { mkdir, readFile, rename, stat, writeFile, chmod } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { GatewayConfig, UpstreamSpec } from "./types.js";

/**
 * Gateway configuration + credentials persistence.
 *
 * Storage contract (routing-phase2-execution.md §1.5 Step 2):
 * - config.json     : GatewayConfig, atomic write (tmp + rename), versioned.
 * - credentials.json: plaintext upstream credentials + gateway local token.
 *                     Mode 0600, enforced on every load — a permissive file
 *                     is a hard error (refuse to start, never silently fix).
 * - Atomic write pattern mirrors prompt-history-store.ts (tmp + rename).
 *
 * Fingerprint rule (§0.3 invariant 1): only the LAST 4 chars of a credential
 * may leave this module (into logs/ledger/WS). Callers get UpstreamSpec
 * objects whose `fingerprint` was computed here.
 */

export interface GatewayPaths {
  rootDir: string;
  configPath: string;
  credentialsPath: string;
}

export function defaultGatewayPaths(): GatewayPaths {
  const rootDir = join(homedir(), ".ccpocket", "gateway");
  return {
    rootDir,
    configPath: join(rootDir, "config.json"),
    credentialsPath: join(rootDir, "credentials.json"),
  };
}

const DEFAULT_LIMITS = {
  connectTimeoutMs: 10_000,
  firstByteTimeoutMs: 300_000,
  idleTimeoutMs: 120_000,
};

/** Build the initial config for a single upstream (P0: deepseek migration). */
export function buildInitialConfig(input: {
  upstreamId: string;
  label: string;
  baseUrl: string;
  fingerprint: string;
}): GatewayConfig {
  const upstream: UpstreamSpec = {
    id: input.upstreamId,
    label: input.label,
    protocol: "anthropic-compat",
    baseUrl: input.baseUrl,
    credentialRef: `${input.upstreamId}-default`,
    fingerprint: input.fingerprint,
    enabled: true,
  };
  return {
    version: 1,
    upstreams: [upstream],
    routing: { defaultUpstreamId: input.upstreamId },
    capture: { enabled: true, dir: join(homedir(), ".ccpocket", "gateway", "captures") },
    limits: { ...DEFAULT_LIMITS },
  };
}

export class ConfigStore {
  private readonly paths: GatewayPaths;

  constructor(paths: Partial<GatewayPaths> = {}) {
    this.paths = { ...defaultGatewayPaths(), ...paths };
  }

  get configPath(): string {
    return this.paths.configPath;
  }

  get credentialsPath(): string {
    return this.paths.credentialsPath;
  }

  // -- config.json ---------------------------------------------------------

  async loadConfig(): Promise<GatewayConfig | null> {
    let raw: string;
    try {
      raw = await readFile(this.paths.configPath, "utf-8");
    } catch {
      return null; // not initialized yet
    }
    const parsed = JSON.parse(raw) as GatewayConfig; // corrupt file → throw (caller decides)
    if (parsed.version !== 1) {
      throw new Error(`gateway config: unsupported version ${String(parsed.version)}`);
    }
    // Forward-compatible defaults for missing optional blocks.
    parsed.capture ??= { enabled: false, dir: join(this.paths.rootDir, "captures") };
    parsed.limits ??= { ...DEFAULT_LIMITS };
    return parsed;
  }

  async saveConfig(config: GatewayConfig): Promise<void> {
    await atomicWriteJson(this.paths.configPath, config);
  }

  // -- credentials.json ----------------------------------------------------

  async loadCredentials(): Promise<Record<string, string>> {
    await this.assertCredentialsPermissions();
    const raw = await readFile(this.paths.credentialsPath, "utf-8");
    return JSON.parse(raw) as Record<string, string>;
  }

  async saveCredentials(credentials: Record<string, string>): Promise<void> {
    await mkdir(dirname(this.paths.credentialsPath), { recursive: true });
    await atomicWriteJson(this.paths.credentialsPath, credentials);
    await chmod(this.paths.credentialsPath, 0o600);
    await this.assertCredentialsPermissions();
  }

  /** Hard error when credentials are group/other readable (§0.3 invariant 1). */
  async assertCredentialsPermissions(): Promise<void> {
    let st;
    try {
      st = await stat(this.paths.credentialsPath);
    } catch {
      return; // nothing on disk yet — saveCredentials will set the mode
    }
    if ((st.mode & 0o077) !== 0) {
      throw new Error(
        `gateway credentials file is too permissive (${(st.mode & 0o777).toString(8)}): ` +
          `refusing to load. Fix with chmod 600 ${this.paths.credentialsPath}`,
      );
    }
  }

  // -- one-time migration from legacy pm2 env ------------------------------

  /**
   * Create config+credentials from the legacy ANTHROPIC_* environment trio.
   * Idempotent: if config.json already exists, returns it unchanged.
   * `generateLocalToken` injects the token factory (crypto) for testability.
   */
  async migrateFromPm2Env(
    env: NodeJS.ProcessEnv,
    generateLocalToken: () => string = () => randomUUID().replace(/-/g, "") + randomUUID().replace(/-/g, ""),
  ): Promise<GatewayConfig | null> {
    const existing = await this.loadConfig();
    if (existing) return existing;

    const baseUrl = env.ANTHROPIC_BASE_URL;
    const token = env.ANTHROPIC_AUTH_TOKEN ?? env.ANTHROPIC_API_KEY;
    if (!baseUrl || !token) {
      throw new Error(
        "gateway migrate: ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN not found in environment",
      );
    }

    const upstreamId = deriveUpstreamId(baseUrl);
    const credentials: Record<string, string> = {
      [`${upstreamId}-default`]: token,
      "gateway.localToken": generateLocalToken(),
    };

    const config = buildInitialConfig({
      upstreamId,
      label: upstreamId,
      baseUrl,
      fingerprint: fingerprintOf(token),
    });

    await this.saveCredentials(credentials);
    await this.saveConfig(config);
    return config;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function atomicWriteJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${randomUUID()}.tmp`;
  await writeFile(tmp, JSON.stringify(value, null, 2), "utf-8");
  await rename(tmp, path);
}

export function fingerprintOf(credential: string): string {
  return credential.slice(-4);
}

/**
 * Derive a stable upstream id from the legacy base URL:
 *   https://api.deepseek.com/anthropic → "deepseek"
 * Falls back to the host when the first path segment is generic.
 */
export function deriveUpstreamId(baseUrl: string): string {
  try {
    const url = new URL(baseUrl);
    const hostParts = url.hostname.split(".");
    const brandish = hostParts.find((p) => p && !["api", "www", "com", "cn", "ai", "net", "org"].includes(p));
    const firstSegment = url.pathname.split("/").filter(Boolean)[0];
    if (firstSegment && !["anthropic", "v1", "vN", "api"].includes(firstSegment)) {
      return firstSegment.toLowerCase();
    }
    return (brandish ?? url.hostname).toLowerCase();
  } catch {
    return "upstream";
  }
}
