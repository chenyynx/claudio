import { describe, expect, it, beforeEach } from "vitest";
import { mkdtemp, readdir, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DecisionLedger, dayKeyOf } from "../decision-ledger.js";
import type { DecisionRecord } from "../../types.js";

function record(overrides: Partial<DecisionRecord> = {}): DecisionRecord {
  return {
    ts: "2026-09-09T08:00:00.000Z",
    requestId: "req-1",
    model: "deepseek-chat",
    upstreamId: "deepseek",
    strategy: "direct",
    status: "ok",
    ...overrides,
  };
}

async function tmpLedger(): Promise<{ ledger: DecisionLedger; dir: string }> {
  const dir = await mkdtemp(join(tmpdir(), "gw-ledger-"));
  const ledger = new DecisionLedger(dir, 90);
  await ledger.init();
  return { ledger, dir };
}

describe("DecisionLedger", () => {
  let ledger: DecisionLedger;
  let dir: string;

  beforeEach(async () => {
    ({ ledger, dir } = await tmpLedger());
  });

  it("append writes one JSONL line per record", async () => {
    ledger.append(record());
    await ledger.flush();
    const raw = await readFile(join(dir, "2026-09-09.jsonl"), "utf-8");
    expect(raw.trimEnd().split("\n")).toHaveLength(1);
    expect(JSON.parse(raw)).toMatchObject({ requestId: "req-1" });
  });

  it("concurrent appends never interleave (100 records, all intact)", async () => {
    for (let i = 0; i < 100; i++) {
      ledger.append(record({ requestId: `req-${i}` }));
    }
    await ledger.flush();
    const raw = await readFile(join(dir, "2026-09-09.jsonl"), "utf-8");
    const lines = raw.trimEnd().split("\n");
    expect(lines).toHaveLength(100);
    // Every line parses — no torn writes.
    const ids = new Set(lines.map((l) => (JSON.parse(l) as DecisionRecord).requestId));
    expect(ids.size).toBe(100);
  });

  it("daily rotation — records land in per-day files", async () => {
    ledger.append(record({ ts: "2026-09-09T10:00:00Z", requestId: "a" }));
    ledger.append(record({ ts: "2026-09-10T10:00:00Z", requestId: "b" }));
    await ledger.flush();
    const files = (await readdir(dir)).sort();
    expect(files).toEqual(["2026-09-09.jsonl", "2026-09-10.jsonl"]);
  });

  it("query filters by status and upstreamId", async () => {
    ledger.append(record({ requestId: "ok-1" }));
    ledger.append(record({ requestId: "err-1", status: "error", errorClass: "rate_limit" }));
    ledger.append(record({ requestId: "ok-2", upstreamId: "kimi" }));
    await ledger.flush();
    const errors = await ledger.query({ status: "error" });
    expect(errors.map((r) => r.requestId)).toEqual(["err-1"]);
    const kimi = await ledger.query({ upstreamId: "kimi" });
    expect(kimi.map((r) => r.requestId)).toEqual(["ok-2"]);
  });

  it("query since/until restricts day range", async () => {
    ledger.append(record({ ts: "2026-09-08T00:00:00Z", requestId: "old" }));
    ledger.append(record({ ts: "2026-09-09T00:00:00Z", requestId: "new" }));
    await ledger.flush();
    const rows = await ledger.query({ since: new Date("2026-09-09T00:00:00Z") });
    expect(rows.map((r) => r.requestId)).toEqual(["new"]);
  });

  it("query limit caps result size", async () => {
    for (let i = 0; i < 10; i++) ledger.append(record({ requestId: `r${i}` }));
    await ledger.flush();
    expect(await ledger.query({ limit: 3 })).toHaveLength(3);
  });

  it("corrupt line is skipped, not thrown", async () => {
    const { writeFile } = await import("node:fs/promises");
    await writeFile(join(dir, "2026-09-09.jsonl"), "{\"requestId\":\"good\"}\n{torn line\n", "utf-8");
    const rows = await ledger.query();
    expect(rows).toHaveLength(1);
  });

  it("dayKeyOf extracts date part", () => {
    expect(dayKeyOf("2026-09-09T08:00:00.000Z")).toBe("2026-09-09");
  });
});
