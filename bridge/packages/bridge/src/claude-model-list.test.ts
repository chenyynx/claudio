import { describe, expect, it } from "vitest";
import { envConfiguredModels, resolveAllowedModel, withEnvModels } from "./claude-model-list";

/**
 * The list the bridge advertises drives the app's model picker (session_list
 * .claudeModels). These cases pin the incident that motivated the module: after
 * a host-level provider switch the picker still offered the old provider's model
 * and every message 400'd.
 */
describe("envConfiguredModels", () => {
  it("collects the declared models in order", () => {
    expect(envConfiguredModels({
      ANTHROPIC_MODEL: "deepseek-v4-flash[1m]",
      ANTHROPIC_DEFAULT_OPUS_MODEL: "deepseek-v4-pro[1m]",
      ANTHROPIC_DEFAULT_SONNET_MODEL: "deepseek-v4-pro[1m]",
      ANTHROPIC_DEFAULT_HAIKU_MODEL: "deepseek-v4-flash[1m]",
      CLAUDE_CODE_SUBAGENT_MODEL: "MiniMaxAI/MiniMax-M3",
    })).toEqual([
      "deepseek-v4-flash[1m]",
      "deepseek-v4-pro[1m]",
      "MiniMaxAI/MiniMax-M3",
    ]);
  });

  it("skips blank, missing and trims whitespace", () => {
    expect(envConfiguredModels({ ANTHROPIC_MODEL: "  x  ", ANTHROPIC_DEFAULT_HAIKU_MODEL: "   " }))
      .toEqual(["x"]);
    expect(envConfiguredModels({})).toEqual([]);
  });
});

describe("withEnvModels", () => {
  it("puts environment models first, then the discovered ones", () => {
    expect(withEnvModels(["claude-opus-4-7", "claude-sonnet-4-6"], {
      ANTHROPIC_MODEL: "deepseek-v4-flash[1m]",
    })).toEqual(["deepseek-v4-flash[1m]", "claude-opus-4-7", "claude-sonnet-4-6"]);
  });

  it("never duplicates a model that appears in both sources", () => {
    expect(withEnvModels(["a", "b"], { ANTHROPIC_MODEL: "b" })).toEqual(["b", "a"]);
  });

  it("the incident: a stale advertised list becomes the current provider's models", () => {
    // discovered would be the SDK/static list; the environment is the truth
    const advertised = withEnvModels(["glm-5.3-flash[1m]"], {
      ANTHROPIC_MODEL: "deepseek-v4-flash[1m]",
      ANTHROPIC_DEFAULT_OPUS_MODEL: "deepseek-v4-pro[1m]",
    });
    expect(advertised[0]).toBe("deepseek-v4-flash[1m]");
    expect(advertised[1]).toBe("deepseek-v4-pro[1m]");
  });

  it("falls back to whatever was discovered when the environment says nothing", () => {
    expect(withEnvModels(["claude-opus-4-7"], {})).toEqual(["claude-opus-4-7"]);
  });
});

/**
 * pp's decision (2026-09-11): a session whose stored model predates a provider
 * switch must not 400 forever. These cases pin the contract of the fallback.
 */
describe("resolveAllowedModel", () => {
  const allowed = ["deepseek-v4-flash[1m]", "deepseek-v4-pro[1m]"];
  const fallback = "deepseek-v4-flash[1m]";

  it("the incident: a pre-switch model falls back to the environment's model", () => {
    expect(resolveAllowedModel("glm-5.3-flash[1m]", allowed, fallback)).toEqual({
      model: fallback,
      fellBackFrom: "glm-5.3-flash[1m]",
    });
  });

  it("a served model passes through untouched (upstream behaviour preserved)", () => {
    expect(resolveAllowedModel("deepseek-v4-pro[1m]", allowed, fallback))
      .toEqual({ model: "deepseek-v4-pro[1m]" });
  });

  it("an absent request is left alone so the SDK default applies", () => {
    expect(resolveAllowedModel(undefined, allowed, fallback)).toEqual({ model: undefined });
    expect(resolveAllowedModel("   ", allowed, fallback)).toEqual({ model: "   " });
  });

  it("with nothing declared in the environment the request is never rewritten", () => {
    // guessing a replacement would silently override the user's choice
    expect(resolveAllowedModel("glm-5.3-flash[1m]", [], undefined))
      .toEqual({ model: "glm-5.3-flash[1m]" });
  });

  it("an empty allowed set still falls back when the environment declares one", () => {
    expect(resolveAllowedModel("glm-5.3-flash[1m]", [], fallback))
      .toEqual({ model: fallback, fellBackFrom: "glm-5.3-flash[1m]" });
  });
});
