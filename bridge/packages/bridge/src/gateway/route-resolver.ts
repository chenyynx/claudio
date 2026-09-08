import type { GatewayConfig, UpstreamSpec } from "./types.js";

/**
 * Route resolution: model string → upstream.
 *
 * P0 semantics (§1.3): single default upstream, model forwarded as-is.
 * The resolver already understands the P1 addressing scheme so the wire
 * behavior never changes when P1 lands:
 *   "upstreamId/model" → that upstream, model part forwarded
 *   bare "model"       → default upstream, model forwarded as-is
 * Unknown upstream id → resolution failure (caller returns 400).
 */

export interface RouteResolution {
  upstream: UpstreamSpec;
  /** Model string forwarded to the upstream (P0: always the raw input). */
  upstreamModel: string;
  /** True when the model used `upstreamId/` addressing. */
  addressed: boolean;
}

export class RouteResolutionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RouteResolutionError";
  }
}

export function resolveRoute(
  config: GatewayConfig,
  rawModel: string,
): RouteResolution {
  const slash = rawModel.indexOf("/");
  if (slash > 0) {
    const upstreamId = rawModel.slice(0, slash);
    const upstream = config.upstreams.find((u) => u.id === upstreamId);
    if (!upstream || !upstream.enabled) {
      throw new RouteResolutionError(
        `unknown upstream "${upstreamId}" in model "${rawModel}"`,
      );
    }
    return { upstream, upstreamModel: rawModel.slice(slash + 1), addressed: true };
  }

  const fallbackId = config.routing.defaultUpstreamId;
  const upstream = config.upstreams.find((u) => u.id === fallbackId);
  if (!upstream || !upstream.enabled) {
    throw new RouteResolutionError(
      `default upstream "${fallbackId}" is not configured or disabled`,
    );
  }
  return { upstream, upstreamModel: rawModel, addressed: false };
}
