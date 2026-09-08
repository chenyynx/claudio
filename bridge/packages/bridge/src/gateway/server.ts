import { createServer, type Server, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdir, appendFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { Dispatcher } from "undici";
import type { GatewayConfig } from "./types.js";
import type { DecisionRecord } from "./types.js";
import { ConfigStore } from "./config-store.js";
import { DecisionLedger } from "./decision-ledger.js";
import { resolveRoute, RouteResolutionError } from "./route-resolver.js";
import { handleMessagesPassthrough, handleCountTokens, type PassthroughDeps } from "./passthrough.js";

/**
 * Gateway HTTP server — loopback-only Anthropic-compatible endpoint.
 *
 * Lifecycle: start() binds 127.0.0.1:<port>; close() drains (stop accepting,
 * wait for in-flight up to graceMs) so pm2 restarts never tear open streams.
 * Auth: Bearer <gateway.localToken> on every route except /gateway/health
 * (loopback is the primary control; Bearer is defense-in-depth, §1.3).
 *
 * The listen function is injected (ctx pattern, §7.1) so this module keeps
 * its zero-import boundary contract toward other bridge modules.
 */

export interface GatewayServerDeps {
  store: ConfigStore;
  ledger: DecisionLedger;
  /** undici request, injected for tests. */
  http: (url: string, opts: Record<string, unknown>) => Promise<Dispatcher.ResponseData>;
  /** listen helper (production passes listenForStartup). */
  listen: (server: Server, port: number, host: string) => Promise<void>;
  port: number;
  /** Max request body bytes (Claude Code payloads with images can be large). */
  maxBodyBytes?: number;
  now?: () => number;
}

const DEFAULT_MAX_BODY = 64 * 1024 * 1024; // 64 MiB

export class GatewayServer {
  private server: Server | null = null;
  private config: GatewayConfig | null = null;
  private credentials: Record<string, string> = {};
  private readonly inFlight = new Set<ServerResponse>();
  private draining = false;

  constructor(private readonly deps: GatewayServerDeps) {}

  async start(): Promise<void> {
    const config = await this.deps.store.loadConfig();
    if (!config) {
      throw new Error(
        "gateway: no config.json — run migrateFromPm2Env first (or the deploy script's migrate step)",
      );
    }
    this.config = config;
    this.credentials = await this.deps.store.loadCredentials();
    await this.deps.ledger.init();
    if (config.capture.enabled) {
      await mkdir(config.capture.dir, { recursive: true });
    }

    this.server = createServer((req, res) => {
      void this.route(req, res);
    });
    // Hard cap total request time at the HTTP layer (handler caps body size).
    this.server.requestTimeout = 0; // streaming responses can be long-lived
    this.server.headersTimeout = 310_000;
    await this.deps.listen(this.server, this.deps.port, "127.0.0.1");
    // eslint-disable-next-line no-console
    console.log(`[gateway] listening on http://127.0.0.1:${this.deps.port} (loopback only)`);
  }

  /** Drain: reject new requests, wait for in-flight responses up to graceMs. */
  async close(graceMs = 10_000): Promise<void> {
    this.draining = true;
    const server = this.server;
    if (!server) return;
    const deadline = Date.now() + graceMs;
    while (this.inFlight.size > 0 && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 50));
    }
    await new Promise<void>((resolve) => server.close(() => resolve()));
    this.server = null;
  }

  // -- routing ---------------------------------------------------------------

  private async route(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = req.url ?? "";
    res.on("finish", () => this.inFlight.delete(res));
    if (this.draining && !url.startsWith("/gateway/health")) {
      res.writeHead(503, { "content-type": "application/json", "retry-after": "1" });
      res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: "gateway draining for restart" } }));
      return;
    }
    this.inFlight.add(res);

    try {
      if (url === "/gateway/health" && req.method === "GET") {
        this.health(res);
        return;
      }
      if (!this.authorize(req, res)) return;

      if (url === "/v1/messages" && req.method === "POST") {
        await this.messages(req, res);
        return;
      }
      if (url === "/v1/messages/count_tokens" && req.method === "POST") {
        await this.countTokens(req, res);
        return;
      }
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "error", error: { type: "not_found_error", message: `no gateway route ${url}` } }));
    } catch (err) {
      // Last-resort guard: a thrown handler must still produce a valid response.
      if (!res.headersSent) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: "gateway internal error" } }));
      } else if (!res.writableEnded) {
        res.end();
      }
      // eslint-disable-next-line no-console
      console.error("[gateway] unhandled:", (err as Error)?.message?.slice(0, 300));
    } finally {
      if (res.writableEnded) this.inFlight.delete(res);
    }
  }

  private health(res: ServerResponse): void {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        ok: true,
        upstreams: this.config?.upstreams.map((u) => ({ id: u.id, protocol: u.protocol, enabled: u.enabled })) ?? [],
        capture: this.config?.capture.enabled ?? false,
      }),
    );
  }

  private authorize(req: IncomingMessage, res: ServerResponse): boolean {
    const token = this.credentials["gateway.localToken"];
    if (!token) {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: "gateway token missing" } }));
      return false;
    }
    const header = req.headers.authorization ?? "";
    if (header !== `Bearer ${token}`) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "error", error: { type: "authentication_error", message: "invalid gateway token" } }));
      return false;
    }
    return true;
  }

  // -- handlers --------------------------------------------------------------

  private async messages(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await readBody(req, this.deps.maxBodyBytes ?? DEFAULT_MAX_BODY, res);
    if (body === null) return; // already responded (413)
    await handleMessagesPassthrough(req, res, body, this.passthroughDeps(req, body), this.upstreamFor(body));
  }

  private async countTokens(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await readBody(req, this.deps.maxBodyBytes ?? DEFAULT_MAX_BODY, res);
    if (body === null) return;
    await handleCountTokens(req, res, body, this.passthroughDeps(req, body), this.upstreamFor(body));
  }

  /** Resolve the upstream lazily from the request body's model (per-request). */
  private upstreamFor(body: string): () => { baseUrl: string; authHeaders: Record<string, string>; id: string } {
    return () => {
      if (!this.config) throw new Error("gateway not started");
      let model = "";
      try {
        model = String((JSON.parse(body) as Record<string, unknown>).model ?? "");
      } catch {
        throw new Error("request body must be JSON with a model field");
      }
      const resolution = resolveRoute(this.config, model); // throws RouteResolutionError → 400 in handler
      const credential = this.credentials[resolution.upstream.credentialRef];
      if (!credential) {
        throw new RouteResolutionError(`upstream "${resolution.upstream.id}" has no credential`);
      }
      return {
        baseUrl: resolution.upstream.baseUrl,
        id: resolution.upstream.id,
        authHeaders: { authorization: `Bearer ${credential}` },
      };
    };
  }

  private passthroughDeps(req: IncomingMessage, body: string): PassthroughDeps {
    const capture = this.config?.capture;
    const requestId = randomUUID();
    if (capture?.enabled) {
      void appendFile(join(capture.dir, "requests.jsonl"), JSON.stringify({ ts: new Date().toISOString(), requestId, body: body.slice(0, 200_000) }) + "\n", "utf-8").catch(() => {});
    }
    return {
      http: this.deps.http,
      now: this.deps.now ?? Date.now,
      newRequestId: () => requestId,
      ledgerAppend: (record: DecisionRecord) => this.deps.ledger.append(record),
    };
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

async function readBody(req: IncomingMessage, maxBytes: number, res: ServerResponse): Promise<string | null> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > maxBytes) {
      res.writeHead(413, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "request body too large" } }));
      return null;
    }
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString("utf-8");
}
