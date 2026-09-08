import { describe, expect, it } from "vitest";
import { resolveRoute, RouteResolutionError } from "../route-resolver.js";
import { buildInitialConfig } from "../config-store.js";
import type { GatewayConfig } from "../../types.js";

function configWith(overrides: Partial<GatewayConfig> = {}): GatewayConfig {
  const base = buildInitialConfig({
    upstreamId: "deepseek",
    label: "DeepSeek",
    baseUrl: "https://api.deepseek.com/anthropic",
    fingerprint: "abcd",
  });
  return { ...base, ...overrides };
}

describe("resolveRoute", () => {
  it("bare model → default upstream, model forwarded as-is", () => {
    const r = resolveRoute(configWith(), "deepseek-chat");
    expect(r.upstream.id).toBe("deepseek");
    expect(r.upstreamModel).toBe("deepseek-chat");
    expect(r.addressed).toBe(false);
  });

  it("addressed model routes to the named upstream", () => {
    const config = configWith();
    config.upstreams.push({
      id: "kimi", label: "Kimi", protocol: "openai-compat",
      baseUrl: "https://api.moonshot.cn/v1", credentialRef: "k-1",
      fingerprint: "ffff", enabled: true,
    });
    const r = resolveRoute(config, "kimi/kimi-k3");
    expect(r.upstream.id).toBe("kimi");
    expect(r.upstreamModel).toBe("kimi-k3");
    expect(r.addressed).toBe(true);
  });

  it("unknown upstream id throws with actionable message", () => {
    expect(() => resolveRoute(configWith(), "nope/model")).toThrow(RouteResolutionError);
    expect(() => resolveRoute(configWith(), "nope/model")).toThrow(/unknown upstream/);
  });

  it("disabled upstream throws", () => {
    const config = configWith();
    config.upstreams[0].enabled = false;
    expect(() => resolveRoute(config, "anything")).toThrow(/not configured or disabled/);
  });

  it("leading slash is not addressing (treated as bare model)", () => {
    const r = resolveRoute(configWith(), "/weird");
    expect(r.addressed).toBe(false);
    expect(r.upstreamModel).toBe("/weird");
  });
});
