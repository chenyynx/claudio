import { describe, expect, it, vi } from "vitest";
import { EventEmitter } from "node:events";
import { Readable } from "node:stream";
import {
  classifyUpstreamStatus,
  mapUpstreamError,
  buildUpstreamHeaders,
  passthroughResponseHeaders,
  SseUsageExtractor,
  handleMessagesPassthrough,
  extractRequestMeta,
  type PassthroughDeps,
} from "../passthrough.js";
import type { DecisionRecord } from "../../types.js";

// -- test doubles -----------------------------------------------------------

function fakeRes() {
  const chunks: Buffer[] = [];
  return {
    statusCode: 0,
    headers: {} as Record<string, string>,
    headersSent: false,
    writableEnded: false,
    writeHead(code: number, headers: Record<string, string>) {
      this.statusCode = code;
      this.headers = headers;
      this.headersSent = true;
      return this;
    },
    write(c: string | Buffer) {
      chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
      return true;
    },
    end(c?: string | Buffer) {
      if (c !== undefined) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
      this.writableEnded = true;
    },
    body() {
      return Buffer.concat(chunks).toString("utf-8");
    },
  };
}

function fakeReq(): EventEmitter & { headers: Record<string, string>; url: string; method: string } {
  const req = new EventEmitter() as EventEmitter & { headers: Record<string, string>; url: string; method: string };
  req.headers = { "content-type": "application/json", authorization: "Bearer client-token" };
  req.url = "/v1/messages";
  req.method = "POST";
  return req;
}

function fakeUpstreamResponse(statusCode: number, chunks: string[], headers: Record<string, string> = {}) {
  const body = Readable.from(chunks.map((c) => Buffer.from(c)));
  return {
    statusCode,
    headers: { "content-type": "text/event-stream", ...headers },
    body: Object.assign(body, {
      text: async () => {
        const parts: Buffer[] = [];
        for await (const c of body) parts.push(c as Buffer);
        return Buffer.concat(parts).toString("utf-8");
      },
    }),
  };
}

function makeDeps(http: PassthroughDeps["http"]) {
  const records: DecisionRecord[] = [];
  let clock = 1000;
  const deps: PassthroughDeps = {
    http,
    now: () => clock++,
    ledgerAppend: (r) => records.push(r),
    newRequestId: () => "req-fixed",
  };
  return { deps, records };
}

const UPSTREAM = { baseUrl: "https://api.deepseek.com/anthropic", authHeaders: { authorization: "Bearer upstream-key" }, id: "deepseek" };

// -- pure helpers -----------------------------------------------------------

describe("classifyUpstreamStatus", () => {
  it("maps status codes to error classes", () => {
    expect(classifyUpstreamStatus(401).errorClass).toBe("auth");
    expect(classifyUpstreamStatus(403).errorClass).toBe("auth");
    expect(classifyUpstreamStatus(429).errorClass).toBe("rate_limit");
    expect(classifyUpstreamStatus(500).errorClass).toBe("upstream_5xx");
    expect(classifyUpstreamStatus(529).errorClass).toBe("upstream_5xx");
    expect(classifyUpstreamStatus(400).errorClass).toBe("bad_request");
  });
});

describe("mapUpstreamError", () => {
  it("produces Anthropic-shaped error bodies", () => {
    const m = mapUpstreamError("rate_limit", 429, "slow down");
    expect(m.anthropicError).toEqual({ type: "error", error: { type: "rate_limit_error", message: "slow down" } });
    expect(mapUpstreamError("auth", 401, "x").anthropicError.error.type).toBe("authentication_error");
    expect(mapUpstreamError("network", 502, "x").anthropicError.error.type).toBe("api_error");
  });
});

describe("headers", () => {
  it("filters hop-by-hop and replaces client auth", () => {
    const h = buildUpstreamHeaders(
      { connection: "keep-alive", "transfer-encoding": "chunked", authorization: "Bearer x", "x-trace": "t" } as never,
      { authorization: "Bearer real" },
    );
    expect(h.connection).toBeUndefined();
    expect(h["transfer-encoding"]).toBeUndefined();
    expect(h.authorization).toBe("Bearer real");
    expect(h["x-trace"]).toBe("t");
  });

  it("response headers drop CORS (gateway sets own)", () => {
    const h = passthroughResponseHeaders({ "access-control-allow-origin": "*", "content-type": "text/event-stream" });
    expect(h["access-control-allow-origin"]).toBeUndefined();
    expect(h["content-type"]).toBe("text/event-stream");
  });
});

describe("SseUsageExtractor", () => {
  it("extracts usage from message_start + message_delta across split chunks", () => {
    const ex = new SseUsageExtractor();
    const f1 = 'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":80}}}\n\n';
    const f2 = 'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":34}}\n\n';
    ex.feed(f1.slice(0, 40), 10);
    ex.feed(f1.slice(40) + f2.slice(0, 20), 20);
    ex.feed(f2.slice(20), 30);
    ex.end();
    expect(ex.toUsage()).toEqual({ input: 120, output: 34, cacheRead: 80, cacheWrite: undefined });
    expect(ex.firstByteAt).toBe(10);
  });

  it("no usage anywhere → undefined", () => {
    const ex = new SseUsageExtractor();
    ex.feed("event: ping\ndata: {}\n\n", 1);
    ex.end();
    expect(ex.toUsage()).toBeUndefined();
  });
});

// -- handler integration ----------------------------------------------------

describe("handleMessagesPassthrough", () => {
  it("happy path: SSE bytes stream through identical, ledger ok with usage", async () => {
    const chunks = [
      'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":10}}}\n\n',
      'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n',
      'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":2}}\n\n',
    ];
    const { deps, records } = makeDeps(vi.fn(async () => fakeUpstreamResponse(200, chunks)) as never);
    const req = fakeReq();
    const res = fakeRes();
    await handleMessagesPassthrough(req as never, res as never, JSON.stringify({ model: "deepseek-chat", stream: true }), deps, () => UPSTREAM);
    expect(res.statusCode).toBe(200);
    expect(res.body()).toBe(chunks.join(""));
    expect(records).toHaveLength(1);
    expect(records[0]).toMatchObject({ status: "ok", upstreamId: "deepseek", usage: { input: 10, output: 2 } });
  });

  it("upstream 429 → rate_limit_error shape + ledger errorClass", async () => {
    const { deps, records } = makeDeps(vi.fn(async () => {
      const r = fakeUpstreamResponse(429, []);
      r.body.text = async () => '{"error":{"message":"slow down"}}';
      return r;
    }) as never);
    const res = fakeRes();
    await handleMessagesPassthrough(fakeReq() as never, res as never, JSON.stringify({ model: "m" }), deps, () => UPSTREAM);
    expect(res.statusCode).toBe(429);
    expect(JSON.parse(res.body()).error.type).toBe("rate_limit_error");
    expect(records[0]).toMatchObject({ status: "error", errorClass: "rate_limit", httpStatus: 429 });
  });

  it("client abort mid-stream → ledger canceled", async () => {
    let pushChunk: ((v: Buffer) => void) | null = null;
    const stream = new Readable({ read() {} });
    const http = vi.fn(async () => ({
      statusCode: 200,
      headers: { "content-type": "text/event-stream" },
      body: stream,
    }));
    const { deps, records } = makeDeps(http as never);
    const req = fakeReq();
    const res = fakeRes();
    const p = handleMessagesPassthrough(req as never, res as never, JSON.stringify({ model: "m", stream: true }), deps, () => UPSTREAM);
    stream.push(Buffer.from('event: message_start\ndata: {"type":"message_start"}\n\n'));
    await new Promise((r) => setImmediate(r));
    req.emit("close"); // client disconnects
    stream.push(Buffer.from("wake")); // real undici errors on abort; mock wakes the loop to hit the checkpoint
    await p;
    expect(records[0]).toMatchObject({ status: "canceled", upstreamId: "deepseek" });
    void pushChunk;
  });

  it("missing model → 400 invalid_request_error, no upstream call", async () => {
    const http = vi.fn();
    const { deps, records } = makeDeps(http as never);
    const res = fakeRes();
    await handleMessagesPassthrough(fakeReq() as never, res as never, "{}", deps, () => UPSTREAM);
    expect(res.statusCode).toBe(400);
    expect(http).not.toHaveBeenCalled();
    expect(records[0].errorClass).toBe("bad_request");
  });

  it("connect failure → 502 api_error + ledger network", async () => {
    const { deps, records } = makeDeps(vi.fn(async () => { throw new Error("connect ECONNREFUSED"); }) as never);
    const res = fakeRes();
    await handleMessagesPassthrough(fakeReq() as never, res as never, JSON.stringify({ model: "m" }), deps, () => UPSTREAM);
    expect(res.statusCode).toBe(502);
    expect(records[0]).toMatchObject({ status: "error", errorClass: "network" });
  });

  it("extractRequestMeta reads model/stream", () => {
    expect(extractRequestMeta({ model: "a", stream: true })).toMatchObject({ model: "a", isStreaming: true });
    expect(extractRequestMeta({})).toMatchObject({ model: "" });
  });
});
