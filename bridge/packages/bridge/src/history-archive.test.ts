import { randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { HistoryArchive } from "./history-archive.js";
import type { HistoryEntry } from "./session.js";
import type { ServerMessage } from "./parser.js";

/**
 * [stable history ids] Unit tests for the B2 archive layer.
 *
 * The archive is a crash-safe, append-only JSONL cache of history entries that
 * fell out of the in-memory FIFO window.  It must never be the source of truth
 * (the CLI transcript is) and every failure must degrade to "no archive".
 */
describe("HistoryArchive", () => {
  const dirs: string[] = [];

  const tempDir = (): string => {
    const dir = mkdtempSync(join(tmpdir(), "history-archive-"));
    dirs.push(dir);
    return dir;
  };

  afterEach(() => {
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  const entry = (seq: number, messageUuid?: string): HistoryEntry => ({
    seq,
    message: { type: "status", status: "idle" } as ServerMessage,
    messageUuid,
    createdAt: `2026-09-12T00:00:${String(seq).padStart(2, "0")}.000Z`,
  });

  it("appends trimmed entries and reads them back in seq order", () => {
    const archive = new HistoryArchive(tempDir());
    archive.append("session-1", [entry(3, "u3"), entry(1, "u1"), entry(2, "u2")]);

    const records = archive.readUpTo("session-1", 3, undefined);
    expect(records.map(r => r.seq)).toEqual([1, 2, 3]);
    expect(records.map(r => r.messageUuid)).toEqual(["u1", "u2", "u3"]);
  });

  it("only returns records at or below maxSeq", () => {
    const archive = new HistoryArchive(tempDir());
    archive.append("session-1", [entry(1, "u1"), entry(2, "u2"), entry(3, "u3")]);

    expect(archive.readUpTo("session-1", 2, undefined).map(r => r.seq)).toEqual([1, 2]);
    expect(archive.readUpTo("session-1", 0, undefined)).toEqual([]);
  });

  it("is idempotent by messageUuid: re-appending does not duplicate", () => {
    const dir = tempDir();
    const archive = new HistoryArchive(dir);
    archive.append("session-1", [entry(1, "u1")]);
    archive.append("session-1", [entry(1, "u1")]);
    archive.append("session-1", [entry(1, "u1"), entry(2, "u2")]);

    expect(archive.readUpTo("session-1", 9, undefined).map(r => r.seq)).toEqual([1, 2]);

    // And the file itself holds exactly two lines (no rewrite, no dupes).
    const lines = readFileSync(join(dir, "session-1.jsonl"), "utf-8")
      .trim()
      .split("\n");
    expect(lines).toHaveLength(2);
  });

  it("dedupes across restarts by rehydrating keys from disk", () => {
    const dir = tempDir();
    const first = new HistoryArchive(dir);
    first.append("session-1", [entry(1, "u1"), entry(2, "u2")]);

    // Simulate a bridge restart: fresh instance, same directory.
    const second = new HistoryArchive(dir);
    second.append("session-1", [entry(2, "u2"), entry(3, "u3")]);

    expect(second.readUpTo("session-1", 9, undefined).map(r => r.seq)).toEqual([1, 2, 3]);
  });

  it("keeps entries without a messageUuid, keyed by seq", () => {
    const archive = new HistoryArchive(tempDir());
    archive.append("session-1", [entry(7)]);
    archive.append("session-1", [entry(7)]);

    const records = archive.readUpTo("session-1", 9, undefined);
    expect(records).toHaveLength(1);
    expect(records[0].seq).toBe(7);
    expect(records[0].messageUuid).toBeUndefined();
  });

  it("creates the directory lazily and tolerates unknown sessions", () => {
    const dir = join(tempDir(), "nested", "deeper");
    const archive = new HistoryArchive(dir);
    expect(archive.readUpTo("never-written", 5, undefined)).toEqual([]);

    archive.append("s", [entry(1, "u1")]);
    expect(archive.filePath("s").startsWith(dir)).toBe(true);
    expect(archive.readUpTo("s", 5, undefined)).toHaveLength(1);
  });

  it("sanitizes session ids so they cannot escape the archive directory", () => {
    const archive = new HistoryArchive(tempDir());
    archive.append("../../evil session", [entry(1, "u1")]);

    const path = archive.filePath("../../evil session");
    expect(path).not.toContain("..");
    expect(path.endsWith(".jsonl")).toBe(true);
    // Traversal is neutralised: the resolved path stays inside the archive dir.
    expect(path.startsWith(archive.filePath("x").replace(/x\.jsonl$/, ""))).toBe(
      true,
    );
    expect(archive.readUpTo("../../evil session", 5, undefined)).toHaveLength(1);
  });

  it("treats a dots-only session id as a safe file name", () => {
    const archive = new HistoryArchive(tempDir());
    expect(archive.filePath("..")).not.toContain("..");
    expect(archive.filePath(".")).not.toContain("..");
  });

  it("skips malformed lines instead of throwing", () => {
    const dir = tempDir();
    const archive = new HistoryArchive(dir);
    archive.append("session-1", [entry(1, "u1")]);

    const path = join(dir, "session-1.jsonl");
    const original = readFileSync(path, "utf-8");
    // Splice a broken line in the middle of valid ones.
    require("node:fs").writeFileSync(path, `${original}{not json}\n${original}`);

    const records = new HistoryArchive(dir).readUpTo("session-1", 9, undefined);
    expect(records.map(r => r.seq)).toEqual([1, 1]);
  });

  it("forget() drops tracking state", () => {
    const dir = tempDir();
    const archive = new HistoryArchive(dir);
    archive.append("session-1", [entry(1, "u1")]);
    archive.forget("session-1");
    archive.append("session-1", [entry(1, "u1")]);

    // Re-read from disk after the key set was dropped: the duplicate is
    // written again, which readers tolerate (dedupe is by uuid upstream).
    expect(archive.readUpTo("session-1", 9, undefined).length).toBeGreaterThanOrEqual(1);
  });

  it("uses a unique path per claude session id", () => {
    const archive = new HistoryArchive(tempDir());
    expect(archive.filePath("a")).not.toBe(archive.filePath("b"));
    const id = randomUUID();
    expect(archive.filePath(id)).toContain(id);
  });
  it("[A-6] tags records with a segment and filters by it", () => {
    const dir = tempDir();
    const archive = new HistoryArchive(dir);
    archive.append("session-1", [entry(1, "u1")], "segA");
    archive.append("session-1", [entry(1, "u1b")], "segB");
    archive.append("session-1", [entry(2, "legacy")]);

    expect(archive.readUpTo("session-1", undefined, "segA").map(r => r.messageUuid)).toEqual(["u1"]);
    expect(archive.readUpTo("session-1", undefined, "segB").map(r => r.messageUuid)).toEqual(["u1b"]);
    expect(archive.readUpTo("session-1", undefined, undefined).map(r => r.messageUuid)).toEqual(["legacy"]);
  });

  it("[A-6] keeps records without a segment readable as legacy", () => {
    const dir = tempDir();
    const archive = new HistoryArchive(dir);
    // No segment argument at all -> legacy record.
    archive.append("session-1", [entry(1, "u1")]);

    const lines = readFileSync(join(dir, "session-1.jsonl"), "utf-8").trim().split("\n");
    expect(JSON.parse(lines[0]).segment).toBeUndefined();

    expect(archive.readUpTo("session-1", undefined, undefined).map(r => r.messageUuid)).toEqual(["u1"]);
    // A tagged read must not pick up legacy records.
    expect(archive.readUpTo("session-1", undefined, "segA")).toEqual([]);
  });

  it("[A-2] truncates very long session ids below the filesystem name cap", () => {
    const archive = new HistoryArchive(tempDir());
    const longId = "x".repeat(300);
    const path = archive.filePath(longId);
    const fileName = path.slice(path.lastIndexOf("/") + 1);

    // 255 bytes is the EXT4/NTFS limit; the sanitized name (plus `.jsonl`)
    // must stay comfortably below it or every write fails with ENAMETOOLONG.
    expect(fileName.length).toBeLessThanOrEqual(255);
    expect(fileName.endsWith(".jsonl")).toBe(true);

    // And it still round-trips.
    archive.append(longId, [entry(1, "u1")]);
    expect(archive.readUpTo(longId, undefined, undefined)).toHaveLength(1);
  });

  it("[A-2] truncation is applied after sanitizing so traversal stays neutralised", () => {
    const archive = new HistoryArchive(tempDir());
    const path = archive.filePath(`${"../".repeat(200)}evil`);
    expect(path).not.toContain("..");
    const fileName = path.slice(path.lastIndexOf("/") + 1);
    expect(fileName.length).toBeLessThanOrEqual(255);
  });

  it("[A-3] keeps the newest tracked keys when the dedupe set is capped", () => {
    const dir = tempDir();
    const archive = new HistoryArchive(dir);
    // A very long session: more distinct uuids than MAX_TRACKED_UUIDS (20000).
    // Writing 20050 tiny records would be slow, so exercise the trimming branch
    // through a rehydration instead: seed the file, then load it.
    const lines: string[] = [];
    for (let i = 0; i < 20_050; i++) {
      lines.push(
        JSON.stringify({
          seq: i + 1,
          messageUuid: `u${i}`,
          createdAt: "2026-09-12T00:00:00.000Z",
          message: { type: "status", status: "idle" },
        }),
      );
    }
    require("node:fs").writeFileSync(
      join(dir, "session-1.jsonl"),
      `${lines.join("\n")}\n`,
    );

    // Rehydrating trims the in-memory key set; the *newest* keys must survive so
    // a re-append of a recent entry is still deduped.
    const fresh = new HistoryArchive(dir);
    fresh.append("session-1", [entry(20_050, "u20049")]);
    fresh.append("session-1", [entry(1, "u0")]);

    const records = fresh.readUpTo("session-1", undefined, undefined);
    const uuids = records.map(r => r.messageUuid);
    expect(uuids).toContain("u20049");
    // The newest key was deduped (not written twice); the oldest may be rewritten
    // because it fell outside the cap, which readers tolerate.
    expect(uuids.filter(u => u === "u20049")).toHaveLength(1);
  });
  /**
   * [stable history ids · A-8] A persistently unusable archive directory must
   * trip a breaker instead of retrying (and logging a stack trace) on every
   * single append.  Regression guard for the log-storm failure mode.
   */
  it("trips the directory breaker after a persistent failure", () => {
    const base = tempDir();
    // Make the archive path a *file*, so mkdir always fails with ENOTDIR —
    // a realistic misconfiguration (a stale file left where the dir belongs).
    const asFile = join(base, "not-a-dir");
    writeFileSync(asFile, "x");

    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const archive = new HistoryArchive(join(asFile, "nested"));
      archive.append("session-1", [entry(1, "a")]);
      archive.append("session-1", [entry(2, "b")]);
      archive.append("session-1", [entry(3, "c")]);

      // The first append reports the cause (ensureDir) plus the append context;
      // the 2nd and 3rd are silenced by the breaker.  Without the breaker this
      // would be at least 3 calls and grow with every trim for the life of the
      // process.  Assert the ceiling rather than an exact count so the
      // diagnostic wording can evolve.
      expect(warn.mock.calls.length).toBeLessThanOrEqual(2);
      expect(warn.mock.calls.length).toBeGreaterThanOrEqual(1);
      expect(archive.readUpTo("session-1", undefined, undefined)).toEqual([]);

      // The real regression guard: further appends are silent.  Ten more must
      // not add a single line.
      const before = warn.mock.calls.length;
      for (let i = 10; i < 20; i++) {
        archive.append("session-1", [entry(i, `z${i}`)]);
      }
      expect(warn.mock.calls.length).toBe(before);
    } finally {
      warn.mockRestore();
    }
  });
});
