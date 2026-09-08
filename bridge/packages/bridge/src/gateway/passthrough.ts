import type { IncomingMessage, ServerResponse } from "node:http";
import { pipeline } from "node:stream/promises";
import type { Dispatcher } from "undici";
import type { DecisionRecord, DecisionUsage, ErrorClass, MappedUpstreamError } from "./types.js";

/**
 * Anthropic passthrough handler (P0 core).
 *
 * Forwards /v1/messages (+ /count_tokens) to the resolved upstream verbatim —
 * SSE bytes stream through unbuffered. Implements §1.5 Step 4 boundary list:
 *  1. client abort → abort upstream, ledger "canceled", no partial headers
 *  2. connect/DNS failure → 502 api_error
 *  3. upstream 401/403 → authentication_error
 *  4. upstream 429 → rate_limit_error
 *  5. upstream 5xx → api_error
 *  6. first-byte / idle timeout → 504
 *  7. count_tokens proxied without streaming semantics
 *  8. hop-by-hop headers filtered
 *  9. SSE keep-alive comment frames during upstream silence (nginx+CF safety)
 * 10. abort signal checked at every pump step (CCR pattern)
 */

const HOP_BY_HOP = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length",
]);

export interface PassthroughDeps {
  /** undici request (injected for testability). */
  http: (url: string, opts: Record<string, unknown>) => Promise<Dispatcher.ResponseData>;
  /** Injectable clock for tests. */
  now: () => number;
  ledgerAppend: (record: DecisionRecord) => void;
  newRequestId: () => string;
}

interface RequestMeta {
  requestId: string;
  model: string;
  isStreaming: boolean;
}

export function extractRequestMeta(body: unknown): RequestMeta {
  const model =
    typeof body === "object" && body !== null && "model" in body
      ? String((body as Record<string, unknown>).model ?? "")
      : "";
  const isStreaming =
    typeof body === "object" && body !== null && "stream" in body
      ? (body as Record<string, unknown>).stream === true
      : false;
  return { requestId: "", model, isStreaming };
}

export function mapUpstreamError(errorClass: ErrorClass, httpStatus: number, message: string): MappedUpstreamError {
  const anthropicType =
    errorClass === "auth" ? "authentication_error" :
    errorClass === "rate_limit" ? "rate_limit_error" :
    errorClass === "bad_request" ? "invalid_request_error" :
    "api_error";
  return {
    httpStatus,
    errorClass,
    anthropicError: { type: "error", error: { type: anthropicType, message } },
  };
}

export function classifyUpstreamStatus(status: number): { errorClass: ErrorClass; httpStatus: number } {
  if (status === 401 || status === 403) return { errorClass: "auth", httpStatus: status };
  if (status === 429) return { errorClass: "rate_limit", httpStatus: status };
  if (status >= 500) return { errorClass: "upstream_5xx", httpStatus: status };
  if (status >= 400) return { errorClass: "bad_request", httpStatus: status };
  return { errorClass: "unknown", httpStatus: status };
}

// ---------------------------------------------------------------------------
// SSE usage extraction (light scan of passthrough bytes, never buffers stream)
// ---------------------------------------------------------------------------

export class SseUsageExtractor {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
  firstByteAt?: number;
  private buffer = "";

  feed(text: string, nowMs: number): void {
    if (this.firstByteAt === undefined) this.firstByteAt = nowMs;
    this.buffer += text;
    const frames = this.buffer.split("\n\n");
    this.buffer = frames.pop() ?? "";
    for (const frame of frames) this.scanFrame(frame);
  }

  end(): void {
    if (this.buffer) this.scanFrame(this.buffer);
    this.buffer = "";
  }

  private scanFrame(frame: string): void {
    const typeMatch = frame.match(/"type"\s*:\s*"(message_start|message_delta)"/);
    if (!typeMatch) return;
    const usageMatch = frame.match(/"usage"\s*:\s*\{([^}]*)\}/);
    if (!usageMatch) return;
    const num = (key: string): number | undefined => {
      const m = usageMatch[1].match(new RegExp(`"${key}"\\s*:\\s*(\\d+)`));
      return m ? Number(m[1]) : undefined;
    };
    if (typeMatch[1] === "message_start") {
      this.input = num("input_tokens") ?? this.input;
      this.cacheRead = num("cache_read_input_tokens") ?? this.cacheRead;
      this.cacheWrite = num("cache_creation_input_tokens") ?? this.cacheWrite;
    } else {
      this.output = num("output_tokens") ?? this.output;
    }
  }

  toUsage(): DecisionUsage | undefined {
    if (this.input === undefined && this.output === undefined && this.cacheRead === undefined && this.cacheWrite === undefined) {
      return undefined;
    }
    return { input: this.input, output: this.output, cacheRead: this.cacheRead, cacheWrite: this.cacheWrite };
  }
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

export function buildUpstreamHeaders(
  reqHeaders: IncomingMessage["headers"],
  upstreamAuth: Record<string, string>,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(reqHeaders)) {
    const lower = key.toLowerCase();
    if (HOP_BY_HOP.has(lower)) continue;
    if (lower === "authorization" || lower.startsWith("x-api-key")) continue;
    if (typeof value === "string") out[key] = value;
    else if (Array.isArray(value)) out[key] = value.join(", ");
  }
  Object.assign(out, upstreamAuth);
  return out;
}

export function passthroughResponseHeaders(upstreamHeaders: Record<string, string | string[] | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(upstreamHeaders)) {
    const lower = key.toLowerCase();
    if (HOP_BY_HOP.has(lower)) continue;
    if (lower.startsWith("access-control-")) continue;
    if (typeof value === "string") out[key] = value;
    else if (Array.isArray(value)) out[key] = value.join(", ");
  }
  return out;
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

interface UpstreamRef { baseUrl: string; authHeaders: Record<string, string>; id: string }

export async function handleMessagesPassthrough(
  req: IncomingMessage,
  res: ServerResponse,
  body: string,
  deps: PassthroughDeps,
  getUpstream: () => UpstreamRef,
): Promise<void> {
  const started = deps.now();
  let meta: RequestMeta = { requestId: deps.newRequestId(), model: "", isStreaming: false };
  try {
    meta = extractRequestMeta(JSON.parse(body));
    meta.requestId = deps.newRequestId();
  } catch {
    // parse failure → 400 path below
  }

  const badRequest = (message: string, upstreamId = "none"): void => {
    const mapped = mapUpstreamError("bad_request", 400, message);
    res.writeHead(mapped.httpStatus, { "content-type": "application/json" });
    res.end(JSON.stringify(mapped.anthropicError));
    deps.ledgerAppend({
      ts: new Date(started).toISOString(), requestId: meta.requestId, model: meta.model,
      upstreamId, strategy: "direct", status: "error", errorClass: "bad_request",
      httpStatus: 400, totalMs: deps.now() - started,
    });
  };

  if (!meta.model) {
    badRequest("request body must be JSON with a model field");
    return;
  }

  let upstream: UpstreamRef;
  try {
    upstream = getUpstream();
  } catch (err) {
    badRequest(err instanceof Error ? err.message : String(err));
    return;
  }

  const upstreamUrl = joinUrl(upstream.baseUrl, req.url ?? "/v1/messages");
  const headers = buildUpstreamHeaders(req.headers, upstream.authHeaders);
  const controller = new AbortController();
  const onClientClose = () => controller.abort();
  req.on("close", onClientClose);

  const usage = new SseUsageExtractor();
  let upstreamStatus = 0;

  try {
    const upstreamRes = await deps.http(upstreamUrl, {
      method: req.method ?? "POST",
      headers,
      body,
      signal: controller.signal,
    });
    upstreamStatus = upstreamRes.statusCode;

    if (upstreamRes.statusCode >= 400) {
      const errText = await upstreamRes.body.text();
      const { errorClass, httpStatus } = classifyUpstreamStatus(upstreamRes.statusCode);
      const mapped = mapUpstreamError(errorClass, httpStatus, errText.slice(0, 500) || `upstream ${upstreamRes.statusCode}`);
      if (!res.headersSent) {
        res.writeHead(mapped.httpStatus, { "content-type": "application/json" });
        res.end(JSON.stringify(mapped.anthropicError));
      }
      deps.ledgerAppend({
        ts: new Date(started).toISOString(), requestId: meta.requestId, model: meta.model,
        upstreamId: upstream.id, strategy: "direct", status: "error",
        errorClass, httpStatus: upstreamRes.statusCode, totalMs: deps.now() - started,
      });
      return;
    }

    const resHeaders = passthroughResponseHeaders(upstreamRes.headers as Record<string, string | string[]>);
    res.writeHead(upstreamRes.statusCode, resHeaders);

    const decoder = new TextDecoder();
    let lastActivity = deps.now();
    const KEEP_ALIVE_MS = 15_000;
    let clientAborted = false;

    const keepAliveTimer = setInterval(() => {
      if (!clientAborted && !res.writableEnded && deps.now() - lastActivity >= KEEP_ALIVE_MS) {
        res.write(": keep-alive\n\n");
      }
    }, 5_000);

    try {
      const bodyStream = upstreamRes.body as unknown as AsyncIterable<Buffer>;
      for await (const chunk of bodyStream) {
        const now = deps.now();
        lastActivity = now;
        usage.feed(decoder.decode(chunk as Buffer, { stream: true }), now);
        if (controller.signal.aborted) {
          clientAborted = true;
          break;
        }
        res.write(chunk as Buffer);
      }
      usage.end();
      if (clientAborted) {
        deps.ledgerAppend({
          ts: new Date(started).toISOString(), requestId: meta.requestId, model: meta.model,
          upstreamId: upstream.id, strategy: "direct", status: "canceled",
          totalMs: deps.now() - started, usage: usage.toUsage(),
        });
        if (!res.writableEnded) res.end();
        return;
      }
      deps.ledgerAppend({
        ts: new Date(started).toISOString(), requestId: meta.requestId, model: meta.model,
        upstreamId: upstream.id, strategy: "direct", status: "ok",
        httpStatus: upstreamStatus,
        latencyMs: usage.firstByteAt !== undefined ? usage.firstByteAt - started : undefined,
        totalMs: deps.now() - started, usage: usage.toUsage(),
      });
      res.end();
    } finally {
      clearInterval(keepAliveTimer);
    }
  } catch (err) {
    if (controller.signal.aborted) {
      deps.ledgerAppend({
        ts: new Date(started).toISOString(), requestId: meta.requestId, model: meta.model,
        upstreamId: upstream.id, strategy: "direct", status: "canceled",
        totalMs: deps.now() - started, usage: usage.toUsage(),
      });
      if (!res.writableEnded) res.end();
      return;
    }
    const isTimeout = err instanceof Error && /timeout|headers-timeout|body-timeout/i.test(err.message);
    const mapped = mapUpstreamError(
      isTimeout ? "timeout" : "network",
      isTimeout ? 504 : 502,
      isTimeout ? "upstream timeout" : `upstream connection failed: ${(err as Error)?.message?.slice(0, 200)}`,
    );
    if (!res.headersSent) {
      res.writeHead(mapped.httpStatus, { "content-type": "application/json" });
      res.end(JSON.stringify(mapped.anthropicError));
    } else if (!res.writableEnded) {
      res.end();
    }
    deps.ledgerAppend({
      ts: new Date(started).toISOString(), requestId: meta.requestId, model: meta.model,
      upstreamId: upstream.id, strategy: "direct", status: "error",
      errorClass: mapped.errorClass, httpStatus: mapped.httpStatus, totalMs: deps.now() - started,
    });
  } finally {
    req.off("close", onClientClose);
  }
}

// ---------------------------------------------------------------------------
// count_tokens (non-streaming proxy)
// ---------------------------------------------------------------------------

export async function handleCountTokens(
  req: IncomingMessage,
  res: ServerResponse,
  body: string,
  deps: PassthroughDeps,
  getUpstream: () => UpstreamRef,
): Promise<void> {
  const started = deps.now();
  let model = "";
  try {
    model = extractRequestMeta(JSON.parse(body)).model;
  } catch { /* → 400 */ }
  if (!model) {
    const mapped = mapUpstreamError("bad_request", 400, "request body must be JSON with a model field");
    res.writeHead(mapped.httpStatus, { "content-type": "application/json" });
    res.end(JSON.stringify(mapped.anthropicError));
    return;
  }
  let upstream: UpstreamRef;
  try {
    upstream = getUpstream();
  } catch (err) {
    const mapped = mapUpstreamError("bad_request", 400, err instanceof Error ? err.message : String(err));
    res.writeHead(mapped.httpStatus, { "content-type": "application/json" });
    res.end(JSON.stringify(mapped.anthropicError));
    return;
  }
  try {
    const upstreamRes = await deps.http(joinUrl(upstream.baseUrl, "/v1/messages/count_tokens"), {
      method: "POST",
      headers: buildUpstreamHeaders(req.headers, upstream.authHeaders),
      body,
    });
    const text = await upstreamRes.body.text();
    if (upstreamRes.statusCode >= 400) {
      const { errorClass, httpStatus } = classifyUpstreamStatus(upstreamRes.statusCode);
      const mapped = mapUpstreamError(errorClass, httpStatus, text.slice(0, 500) || `upstream ${upstreamRes.statusCode}`);
      res.writeHead(mapped.httpStatus, { "content-type": "application/json" });
      res.end(JSON.stringify(mapped.anthropicError));
      deps.ledgerAppend({
        ts: new Date(started).toISOString(), requestId: deps.newRequestId(), model,
        upstreamId: upstream.id, strategy: "direct", status: "error", errorClass,
        httpStatus: upstreamRes.statusCode, totalMs: deps.now() - started,
      });
      return;
    }
    res.writeHead(upstreamRes.statusCode, { "content-type": "application/json" });
    res.end(text);
    deps.ledgerAppend({
      ts: new Date(started).toISOString(), requestId: deps.newRequestId(), model,
      upstreamId: upstream.id, strategy: "direct", status: "ok",
      httpStatus: upstreamRes.statusCode, totalMs: deps.now() - started,
    });
  } catch (err) {
    const mapped = mapUpstreamError("network", 502, `count_tokens upstream failed: ${(err as Error)?.message?.slice(0, 200)}`);
    res.writeHead(mapped.httpStatus, { "content-type": "application/json" });
    res.end(JSON.stringify(mapped.anthropicError));
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function joinUrl(base: string, path: string): string {
  if (path.startsWith("/")) return base.replace(/\/$/, "") + path;
  return base.replace(/\/$/, "") + "/" + path;
}
