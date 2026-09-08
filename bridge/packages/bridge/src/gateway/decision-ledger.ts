import { mkdir, appendFile, readdir, stat, unlink } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import type { DecisionRecord } from "./types.js";

/**
 * Decision ledger — one JSONL row per gateway request, daily rotation.
 *
 * Pattern mirrors debug-trace-store.ts: a per-file write chain
 * (Map<string, Promise>) serializes appends so concurrent requests never
 * interleave partial lines. Query API linearly scans the relevant day files.
 * Retention: default 90 days, pruned async on init.
 */

export interface LedgerQuery {
  since?: Date;
  until?: Date;
  upstreamId?: string;
  status?: "ok" | "error" | "canceled";
  model?: string;
  limit?: number;
}

export class DecisionLedger {
  private readonly rootDir: string;
  private readonly retentionDays: number;
  /** Serializes appends per date-file (debug-trace-store writeChains pattern). */
  private readonly writeChains = new Map<string, Promise<void>>();

  constructor(rootDir: string = join(homedir(), ".ccpocket", "gateway", "decisions"), retentionDays = 90) {
    this.rootDir = rootDir;
    this.retentionDays = retentionDays;
  }

  async init(): Promise<void> {
    await mkdir(this.rootDir, { recursive: true });
    // Retention pruning is fire-and-forget: never block startup on cleanup.
    void this.pruneExpired().catch(() => {});
  }

  /** Append one decision record. Safe under concurrency (write chain). */
  append(record: DecisionRecord): void {
    const day = dayKeyOf(record.ts);
    const file = this.fileForDay(day);
    const prev = this.writeChains.get(day) ?? Promise.resolve();
    const next = prev.then(() => appendFile(file, JSON.stringify(record) + "\n", "utf-8")).catch(() => {
      // Ledger write must never crash the request path; surface via event.
      // (P0: swallow; a dedicated metric hook arrives with P2 stats.)
    });
    this.writeChains.set(day, next);
  }

  /** Resolves when all pending appends are on disk (test/ shutdown helper). */
  async flush(): Promise<void> {
    await Promise.all([...this.writeChains.values()]);
  }

  async query(query: LedgerQuery = {}): Promise<DecisionRecord[]> {
    const days = await this.listDayFiles();
    const selected = days.filter((d) => dayInRange(d, query));
    const out: DecisionRecord[] = [];
    // Newest day first; within a day, natural (chronological) order.
    for (const day of selected.reverse()) {
      const rows = await readDayFile(this.fileForDay(day));
      for (const row of rows) {
        if (query.upstreamId && row.upstreamId !== query.upstreamId) continue;
        if (query.status && row.status !== query.status) continue;
        if (query.model && row.model !== query.model) continue;
        out.push(row);
      }
      if (query.limit && out.length >= query.limit) break;
    }
    return query.limit ? out.slice(0, query.limit) : out;
  }

  async countByStatus(since: Date): Promise<{ ok: number; error: number; canceled: number }> {
    const counts = { ok: 0, error: 0, canceled: 0 };
    for (const row of await this.query({ since })) {
      counts[row.status] += 1;
    }
    return counts;
  }

  // -- internals ------------------------------------------------------------

  private fileForDay(day: string): string {
    return join(this.rootDir, `${day}.jsonl`);
  }

  private async listDayFiles(): Promise<string[]> {
    try {
      const entries = await readdir(this.rootDir);
      return entries.filter((e) => e.endsWith(".jsonl")).map((e) => e.replace(".jsonl", "")).sort();
    } catch {
      return [];
    }
  }

  private async pruneExpired(): Promise<void> {
    const cutoff = Date.now() - this.retentionDays * 86_400_000;
    for (const day of await this.listDayFiles()) {
      const ts = Date.parse(day);
      if (Number.isFinite(ts) && ts < cutoff) {
        await unlink(this.fileForDay(day)).catch(() => {});
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers (exported for tests)
// ---------------------------------------------------------------------------

export function dayKeyOf(isoTs: string): string {
  return isoTs.slice(0, 10);
}

function dayInRange(day: string, query: LedgerQuery): boolean {
  const t = Date.parse(day); // midnight UTC of that day
  if (query.until && t > query.until.getTime()) return false;
  const dayEnd = t + 86_399_000;
  if (query.since && dayEnd < query.since.getTime()) return false;
  return true;
}

async function readDayFile(path: string): Promise<DecisionRecord[]> {
  const { readFile } = await import("node:fs/promises");
  let raw: string;
  try {
    raw = await readFile(path, "utf-8");
  } catch {
    return [];
  }
  const out: DecisionRecord[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as DecisionRecord);
    } catch {
      // Skip torn/corrupt line — ledger is advisory data, never block reads.
    }
  }
  return out;
}

export function newRequestId(): string {
  return randomUUID();
}
