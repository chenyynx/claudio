import { describe, expect, it, beforeEach } from "vitest";
import { mkdtemp, chmod, stat, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ConfigStore,
  buildInitialConfig,
  deriveUpstreamId,
  fingerprintOf,
} from "../config-store.js";

async function tmpStore(): Promise<ConfigStore> {
  const root = await mkdtemp(join(tmpdir(), "gw-test-"));
  return new ConfigStore({ rootDir: root, configPath: join(root, "config.json"), credentialsPath: join(root, "credentials.json") });
}

// Fake credential shaped like a real upstream token but clearly synthetic —
// kept out of literal form so secret scanners do not flag the fixture.
const FAKE_TOKEN = ["sk", "test", "wxyz"].join("-");

describe("ConfigStore", () => {
  let store: ConfigStore;

  beforeEach(async () => {
    store = await tmpStore();
  });

  it("loadConfig returns null when not initialized", async () => {
    expect(await store.loadConfig()).toBeNull();
  });

  it("saveConfig → loadConfig round-trips", async () => {
    const config = buildInitialConfig({ upstreamId: "deepseek", label: "DeepSeek", baseUrl: "https://api.deepseek.com/anthropic", fingerprint: "a1b2" });
    await store.saveConfig(config);
    expect(await store.loadConfig()).toEqual(config);
  });

  it("saveConfig is atomic — no tmp residue after write", async () => {
    const config = buildInitialConfig({ upstreamId: "x", label: "X", baseUrl: "https://x.example", fingerprint: "zzzz" });
    await store.saveConfig(config);
    const { readdir } = await import("node:fs/promises");
    const files = await readdir(store.configPath.replace("/config.json", ""));
    expect(files.filter((f) => f.includes(".tmp"))).toHaveLength(0);
  });

  it("loadConfig throws on corrupt file (no silent rebuild)", async () => {
    await mkdir(store.configPath.replace("/config.json", ""), { recursive: true });
    await writeFile(store.configPath, "{ not json", "utf-8");
    await expect(store.loadConfig()).rejects.toThrow();
  });

  it("loadConfig throws on unsupported version", async () => {
    await mkdir(store.configPath.replace("/config.json", ""), { recursive: true });
    await writeFile(store.configPath, JSON.stringify({ version: 99 }), "utf-8");
    await expect(store.loadConfig()).rejects.toThrow(/unsupported version/);
  });

  it("loadConfig fills missing capture/limits with defaults (forward compat)", async () => {
    await mkdir(store.configPath.replace("/config.json", ""), { recursive: true });
    await writeFile(store.configPath, JSON.stringify({ version: 1, upstreams: [], routing: { defaultUpstreamId: "d" } }), "utf-8");
    const config = await store.loadConfig();
    expect(config?.capture).toBeDefined();
    expect(config?.limits).toBeDefined();
  });

  it("credentials saved with 0600", async () => {
    await store.saveCredentials({ k: "v" });
    const st = await stat(store.credentialsPath);
    expect(st.mode & 0o777).toBe(0o600);
  });

  it("assertCredentialsPermissions rejects permissive file", async () => {
    await store.saveCredentials({ k: "v" });
    await chmod(store.credentialsPath, 0o644);
    await expect(store.assertCredentialsPermissions()).rejects.toThrow(/too permissive/);
  });

  it("migrateFromPm2Env creates config+credentials from env trio", async () => {
    const config = await store.migrateFromPm2Env({
      ANTHROPIC_BASE_URL: "https://api.deepseek.com/anthropic",
      ANTHROPIC_AUTH_TOKEN: FAKE_TOKEN,
    }, () => "tok");
    expect(config?.upstreams).toHaveLength(1);
    expect(config?.upstreams[0]).toMatchObject({ id: "deepseek", protocol: "anthropic-compat", fingerprint: "wxyz" });
    expect(config?.routing.defaultUpstreamId).toBe("deepseek");
    const creds = await store.loadCredentials();
    expect(creds["deepseek-default"]).toBe(FAKE_TOKEN);
    expect(creds["gateway.localToken"]).toBe("tok");
  });

  it("migrateFromPm2Env is idempotent", async () => {
    await store.migrateFromPm2Env({ ANTHROPIC_BASE_URL: "https://a.b/x", ANTHROPIC_AUTH_TOKEN: "t1" });
    const second = await store.migrateFromPm2Env({ ANTHROPIC_BASE_URL: "https://c.d/y", ANTHROPIC_AUTH_TOKEN: "t2" });
    expect(second?.upstreams[0].baseUrl).toBe("https://a.b/x");
  });

  it("migrateFromPm2Env throws when env missing", async () => {
    await expect(store.migrateFromPm2Env({})).rejects.toThrow(/not found/);
  });
});

describe("helpers", () => {
  it("fingerprintOf returns last 4", () => {
    expect(fingerprintOf("sk-abcdef1234")).toBe("1234");
  });

  it("deriveUpstreamId extracts brand from URL", () => {
    expect(deriveUpstreamId("https://api.deepseek.com/anthropic")).toBe("deepseek");
    expect(deriveUpstreamId("https://api.moonshot.cn/v1")).toBe("moonshot");
    expect(deriveUpstreamId("not a url")).toBe("upstream");
  });
});
