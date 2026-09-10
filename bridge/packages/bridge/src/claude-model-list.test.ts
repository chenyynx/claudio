import { describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { envConfiguredModels, hostEnvBlock, resolveAllowedModel, withEnvModels } from "./claude-model-list";

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

/**
 * Host settings hot-reload (the reason a provider switch needs no restart):
 * `sm` rewrites settings.json's env block and never touches pm2, so the file —
 * not process.env — has to be the source of truth.
 */
describe("host settings hot reload", () => {
  function withSettings(env: Record<string, unknown> | string | undefined) {
    const dir = mkdtempSync(join(tmpdir(), "claude-host-env-"));
    const file = join(dir, "settings.json");
    const body = typeof env === "string" ? env : JSON.stringify({ env });
    writeFileSync(file, body, "utf8");
    return { file, done: () => rmSync(dir, { recursive: true, force: true }) };
  }

  it("reads declared models out of the settings file", () => {
    const t = withSettings({ ANTHROPIC_MODEL: "kimi-k3[1m]" });
    try {
      expect(hostEnvBlock(t.file)).toEqual({ ANTHROPIC_MODEL: "kimi-k3[1m]" });
    } finally {
      t.done();
    }
  });

  it("settings.json beats the inherited environment (CC's own precedence)", () => {
    const previousModel = process.env["ANTHROPIC_MODEL"];
    const previousPath = process.env["CLAUDIO_SETTINGS_PATH"];
    process.env["ANTHROPIC_MODEL"] = "stale-from-pm2-snapshot[1m]";
    const t = withSettings({ ANTHROPIC_MODEL: "deepseek-v4-pro[1m]" });
    try {
      // the real default path: no argument, resolved through CLAUDIO_SETTINGS_PATH
      process.env["CLAUDIO_SETTINGS_PATH"] = t.file;
      const models = envConfiguredModels();
      expect(models).toContain("deepseek-v4-pro[1m]");
      expect(models).not.toContain("stale-from-pm2-snapshot[1m]");
    } finally {
      if (previousModel === undefined) delete process.env["ANTHROPIC_MODEL"];
      else process.env["ANTHROPIC_MODEL"] = previousModel;
      if (previousPath === undefined) delete process.env["CLAUDIO_SETTINGS_PATH"];
      else process.env["CLAUDIO_SETTINGS_PATH"] = previousPath;
      t.done();
    }
  });

  it("picks up a rewrite immediately (mtime+size cache invalidation)", () => {
    const dir = mkdtempSync(join(tmpdir(), "claude-host-env-"));
    const file = join(dir, "settings.json");
    try {
      writeFileSync(file, JSON.stringify({ env: { ANTHROPIC_MODEL: "first" } }), "utf8");
      expect(hostEnvBlock(file).ANTHROPIC_MODEL).toBe("first");
      expect(hostEnvBlock(join(dir, "other.json"))).toEqual({}); // a second path cannot reuse the cache entry
      writeFileSync(file, JSON.stringify({ env: { ANTHROPIC_MODEL: "second" } }), "utf8");
      // same content length on purpose: mtime alone must be enough to notice
      const future = new Date(Date.now() + 5000);
      utimesSync(file, future, future);
      expect(hostEnvBlock(file).ANTHROPIC_MODEL).toBe("second");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a corrupt or absent file degrades to the inherited environment, never throws", () => {
    const dir = mkdtempSync(join(tmpdir(), "claude-host-env-"));
    const broken = join(dir, "settings.json");
    writeFileSync(broken, "{ not json", "utf8");
    try {
      expect(hostEnvBlock(broken)).toEqual({});
      expect(hostEnvBlock(join(dir, "missing.json"))).toEqual({});
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
