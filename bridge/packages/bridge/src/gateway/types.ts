/**
 * Gateway module — type definitions.
 *
 * [M0-② 2026-09-09] New `src/gateway/` module per routing-phase2-execution.md §1.4.
 * The gateway is a loopback-only Anthropic-compatible endpoint (127.0.0.1) that
 * forwards Claude Code traffic to configured upstreams, with a decision ledger
 * for every request. P0 = single default upstream, pure passthrough.
 *
 * Boundary contract (routing-phase2-execution.md §7.1): this module imports
 * ONLY node builtins + undici + relative gateway/ files. Zero imports from
 * other bridge modules.
 */

// ---------------------------------------------------------------------------
// Upstream configuration
// ---------------------------------------------------------------------------

export type UpstreamProtocol = "anthropic-compat" | "openai-compat";

/**
 * One configured upstream provider. P0 ships with a single anthropic-compat
 * upstream migrated from the legacy pm2 env trio (ANTHROPIC_BASE_URL etc.).
 * Credentials never live here — `credentialRef` points into the separate
 * credentials store; `fingerprint` (last 4 chars) is the only form that may
 * appear in logs, ledger rows, or WS payloads.
 */
export interface UpstreamSpec {
  /** URL slug, e.g. "deepseek". Stable identifier used in model addressing. */
  id: string;
  /** Human display name, e.g. "DeepSeek". */
  label: string;
  protocol: UpstreamProtocol;
  /** Base URL, e.g. "https://api.deepseek.com/anthropic". */
  baseUrl: string;
  /** Key into the credentials store — never the credential itself. */
  credentialRef: string;
  /** Last 4 characters of the credential, for display only. */
  fingerprint: string;
  enabled: boolean;
}

// ---------------------------------------------------------------------------
// Gateway configuration (persisted as atomic JSON)
// ---------------------------------------------------------------------------

export interface RoutingConfigV1 {
  /** Upstream used for bare model names / unaddressed requests. */
  defaultUpstreamId: string;
}

export interface CaptureConfig {
  enabled: boolean;
  dir: string;
}

export interface GatewayLimits {
  connectTimeoutMs: number;
  firstByteTimeoutMs: number;
  idleTimeoutMs: number;
}

export interface GatewayConfig {
  version: 1;
  upstreams: UpstreamSpec[];
  routing: RoutingConfigV1;
  capture: CaptureConfig;
  limits: GatewayLimits;
}

// ---------------------------------------------------------------------------
// Decision ledger
// ---------------------------------------------------------------------------

export type ErrorClass =
  | "auth"
  | "rate_limit"
  | "upstream_5xx"
  | "network"
  | "timeout"
  | "bad_request"
  | "canceled"
  | "unknown";

export interface DecisionUsage {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
}

/**
 * One row per request the gateway handled. Written to a daily JSONL file.
 * Privacy rule (§0.3 invariant 2): routing metadata only — never message
 * content. `model` is the raw model string from the request, which is what
 * the upstream saw; that is intentional (it is addressing, not content).
 */
export interface DecisionRecord {
  ts: string;
  requestId: string;
  /** Raw model field from the request body. */
  model: string;
  upstreamId: string;
  strategy: "direct";
  status: "ok" | "error" | "canceled";
  errorClass?: ErrorClass;
  httpStatus?: number;
  /** First-byte latency in ms. */
  latencyMs?: number;
  totalMs?: number;
  usage?: DecisionUsage;
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export interface MappedUpstreamError {
  httpStatus: number;
  errorClass: ErrorClass;
  /** Anthropic-shaped error body for the response. */
  anthropicError: {
    type: "error";
    error: { type: string; message: string };
  };
}
