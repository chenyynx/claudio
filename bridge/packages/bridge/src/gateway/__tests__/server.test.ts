import { describe, expect, it, beforeEach, afterEach } from "vitest";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "node:http";
import { GatewayServer } from "../server.js";
import { ConfigStore } from "../config-store.js";
import { DecisionLedger } from "../decision-ledger.js";
import type { DecisionRecord } from "../../types.js";
import { Readable } from "node:stream";

const LOCAL_TOKEN = ["local","Secret","Zeta7f3a"].join("-");

interface Harness {
  gateway: GatewayServer;
  base: string;
  records: DecisionRecord[];
  server: Server;
}

async function startGateway(httpImpl: unknown, opts: { maxBodyBytes?: number } = {}): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "gw-srv-"));
  const store = new ConfigStore({ rootDir: root, configPath: join(root, "config.json"), credentialsPath: join(root, "credentials.json") });
  await store.migrateFromPm2Env(
    { ANTHROPIC_BASE_URL: "https://api.deepseek.com/anthropic", ANTHROPIC_AUTH_TOKEN: ["upstream","Secret","X9"].join("-") },
    () => LOCAL_TOKEN,
  );
  const ledger = new DecisionLedger(join(root, "decisions"));
  const records: DecisionRecord[] = [];
  const origAppend = ledger.append.bind(ledger);
  ledger.append = (r) => { records.push(r); origAppend(r); };

  let captured: Server | null = null;
  const gateway = new GatewayServer({
    store,
    ledger,
    http: httpImpl as never,
    listen: (server, port, host) =>
      new Promise<void>((resolve) => {
        server.listen(0, host, () => resolve());
      }),
    port: 0,
    maxBodyBytes: opts.maxBodyBytes,
  });
  // Wrap start to capture server + real port: reach into private via start side effect.
  const realStart = gateway.start.bind(gateway);
  await realStart();
  // The injected listen resolved with an ephemeral port; find it through the http server.
  const addr = (gateway as unknown as { server: Server }).server.address();
  const base = `http://127.0.0.1:${typeof addr === "object" && addr ? addr.port : 0}`;
  captured = (gateway as unknown as { server: Server }).server;
  return { gateway, base, records, server: captured };
}

function sseResponse(chunks: string[]) {
  return {
    statusCode: 200,
    headers: { "content-type": "text/event-stream" },
    body: Readable.from(chunks.map((c) => Buffer.from(c))),
  };
}

describe("GatewayServer", () => {
  let h: Harness;

  afterEach(async () => {
    if (h) await h.gateway.close(100);
  });

  it("GET /gateway/health is open (no auth)", async () => {
    h = await startGateway(async () => sseResponse([]));
    const res = await fetch(`${h.base}/gateway/health`);
    expect(res.status).toBe(200);
    const json = (await res.json()) as { ok: boolean; upstreams: unknown[] };
    expect(json.ok).toBe(true);
  });

  it("missing bearer → 401", async () => {
    h = await startGateway(async () => sseResponse([]));
    const res = await fetch(`${h.base}/v1/messages`, { method: "POST", body: "{}" });
    expect(res.status).toBe(401);
  });

  it("wrong bearer → 401", async () => {
    h = await startGateway(async () => sseResponse([]));
    const res = await fetch(`${h.base}/v1/messages`, {
      method: "POST",
      headers: { authorization: "Bearer nope", "content-type": "application/json" },
      body: JSON.stringify({ model: "m" }),
    });
    expect(res.status).toBe(401);
  });

  it("unknown route → 404", async () => {
    h = await startGateway(async () => sseResponse([]));
    const res = await fetch(`${h.base}/nope`, {
      method: "POST",
      headers: { authorization: `Bearer ${LOCAL_TOKEN}` },
    });
    expect(res.status).toBe(404);
  });

  it("POST /v1/messages streams through and records ledger", async () => {
    const chunks = [
      'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":7}}}\n\n',
      'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\n',
      'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":1}}\n\n',
    ];
    h = await startGateway(async (_url: string, opts: Record<string, unknown>) => {
      expect((opts.headers as Record<string, string>).authorization).toBe("Bearer " + ["upstream","Secret","X9"].join("-"));
      return sseResponse(chunks);
    });
    const res = await fetch(`${h.base}/v1/messages`, {
      method: "POST",
      headers: { authorization: `Bearer ${LOCAL_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ model: "deepseek-chat", stream: true }),
    });
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toBe(chunks.join(""));
    await new Promise((r) => setTimeout(r, 50));
    expect(h.records).toHaveLength(1);
    expect(h.records[0]).toMatchObject({ status: "ok", upstreamId: "deepseek", usage: { input: 7, output: 1 } });
  });

  it("addressed model with unknown upstream → 400", async () => {
    h = await startGateway(async () => sseResponse([]));
    const res = await fetch(`${h.base}/v1/messages`, {
      method: "POST",
      headers: { authorization: `Bearer ${LOCAL_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ model: "ghost/model" }),
    });
    expect(res.status).toBe(400);
    const json = (await res.json()) as { error?: { message: string } };
    expect(JSON.stringify(json)).toContain("unknown upstream");
  });

  it("oversized body → 413", async () => {
    h = await startGateway(async () => sseResponse([]), { maxBodyBytes: 16 });
    const res = await fetch(`${h.base}/v1/messages`, {
      method: "POST",
      headers: { authorization: `Bearer ${LOCAL_TOKEN}` },
      body: "x".repeat(100),
    });
    expect(res.status).toBe(413);
  });

  it("close() drains and stops accepting new connections", async () => {
    h = await startGateway(async () => sseResponse([]));
    const before = await fetch(`${h.base}/gateway/health`);
    expect(before.status).toBe(200);
    await h.gateway.close(100);
    await expect(fetch(`${h.base}/gateway/health`)).rejects.toThrow();
  });
});
