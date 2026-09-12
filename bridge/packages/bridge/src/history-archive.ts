import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { HistoryEntry } from "./session.js";

/**
 * [stable history ids · B2] Durable archive for history entries that fall out
 * of the in-memory FIFO window (`MAX_HISTORY_PER_SESSION`).
 *
 * Why: the in-memory history is a 100-entry chronological tail.  Once entries
 * are trimmed, `getHistorySince` can no longer serve them, so a client whose
 * cursor falls below the low watermark receives a `compacted` snapshot that is
 * *missing early turns*.  By appending trimmed entries to a per-session
 * JSONL file we keep the full server-side history available and can hand a
 * complete snapshot back to clients that opt into `stable_history_ids`.
 *
 * Design constraints:
 *  - append-only: compaction never rewrites, only appends (crash safe).
 *  - idempotent by `messageUuid`: re-archiving the same entry is a no-op.
 *  - never the source of truth: the Claude CLI transcript remains authoritative;
 *    this file is a cache so a live client does not have to re-read disk.
 *  - safe by default: every failure degrades to "no archive", never throws
 *    into the session hot path.
 *
 * Layout: `~/.ccpocket/bridge/history-archive/{claudeSessionId}.jsonl`
 * One JSON object per line: `{ seq, segment, messageUuid, createdAt, message }`.
 *
 * [stable history ids · A-6] Segment tagging.
 *
 * The archive file is keyed by `claudeSessionId`, which is *shared* across every
 * bridge session that resumes the same Claude conversation — that is exactly
 * what makes the file useful (kill app → reopen → resume must still see the
 * whole conversation).
 *
 * `seq`, however, is **per bridge session**: `SessionInfo.historyRevision`
 * restarts at 0 for every `create()` (`session.ts`), so two bridge sessions
 * resuming the same transcript maintain *independent* seq spaces.  Mixing both
 * into one file makes seq ambiguous: entry 5 of run A and entry 5 of run B
 * collide, and readers that sort or slice by seq would interleave two
 * conversations — the very out-of-order bug this batch exists to fix.
 *
 * Every record therefore carries the random id of the bridge session that
 * archived it.  Readers filter by segment and position by `messageUuid` /
 * `createdAt` (globally stable facts) rather than by seq.
 */

const ARCHIVE_DIR_ENV = "CCPOCKET_HISTORY_ARCHIVE_DIR";

/** Max length of a sanitized session id, comfortably under EXT4's 255-byte name cap. */
const MAX_SESSION_ID_LENGTH = 200;

export interface ArchivedHistoryRecord {
  seq: number;
  /** Random id of the bridge session that archived this record (A-6). */
  segment?: string;
  messageUuid?: string;
  createdAt?: string;
  message: unknown;
}

/** Cap the in-process uuid set so a very long-lived session cannot grow unbounded. */
const MAX_TRACKED_UUIDS = 20_000;

function archiveDir(): string {
  const override = process.env[ARCHIVE_DIR_ENV];
  if (override && override.length > 0) return override;
  return join(homedir(), ".ccpocket", "bridge", "history-archive");
}

/**
 * Per-session on-disk archive of trimmed history entries.
 */
export class HistoryArchive {
  /** `claudeSessionId` -> set of `messageUuid`s already persisted. */
  private readonly seen = new Map<string, Set<string>>();
  private readonly fixedDir?: string;
  private dir: string;
  private dirReady = false;
  /**
   * [stable history ids · A-8] Set once the archive directory proved
   * unwritable (EACCES / EROFS / ENOTDIR / ENOSPC …).
   *
   * Without this, every `trimHistory()` retried the same doomed `mkdirSync`
   * and emitted a full stack trace through `console.warn`.  A read-only root
   * filesystem or a full disk therefore turned one broken deployment into an
   * unbounded log storm from the session hot path.  A persistent filesystem
   * error is not going to fix itself mid-process, so we trip once and stay
   * quiet; `resolveDir()` resets the flag if the target directory changes.
   */
  private dirDisabled = false;
  /** Sessions already loaded from disk (so we dedupe across restarts). */
  private readonly loaded = new Set<string>();

  constructor(dir?: string) {
    this.fixedDir = dir;
    this.dir = dir ?? archiveDir();
  }

  /**
   * Resolve the effective directory, honouring a late environment override.
   * Tests (and relocated deployments) may set the env var after import; the
   * process-wide singleton must pick that up rather than keep writing to the
   * path captured at module load.  Explicit constructor dirs always win.
   */
  private resolveDir(): string {
    if (this.fixedDir !== undefined) {
      this.dir = this.fixedDir;
      return this.dir;
    }
    const configured = archiveDir();
    if (configured !== this.dir) {
      // Directory changed: drop cached dedupe state, it belongs to the old path.
      this.dir = configured;
      this.dirReady = false;
      this.dirDisabled = false;
      this.seen.clear();
      this.loaded.clear();
    }
    return this.dir;
  }

  /** Path of a session's archive file.  Exposed for tests and diagnostics. */
  filePath(claudeSessionId: string): string {
    return join(this.resolveDir(), `${sanitize(claudeSessionId)}.jsonl`);
  }

  /**
   * Append trimmed entries.  Entries without a `messageUuid` are still kept
   * (keyed by seq) so nothing is ever silently dropped.
   *
   * `segment` (when supplied) tags every record with the archiving bridge
   * session so a later reader can tell apart records that merely share a
   * `claudeSessionId`.  Omitting it keeps the legacy behaviour for callers
   * that have no segment concept (and for unit tests).
   */
  append(
    claudeSessionId: string,
    entries: HistoryEntry[],
    segment?: string,
  ): void {
    if (!claudeSessionId || entries.length === 0) return;
    try {
      this.ensureLoaded(claudeSessionId);
      const keys = this.seen.get(claudeSessionId);
      if (!keys) return;

      const lines: string[] = [];
      for (const entry of entries) {
        const key = dedupeKey(entry);
        if (keys.has(key)) continue;
        keys.add(key);
        lines.push(
          JSON.stringify({
            seq: entry.seq,
            segment,
            messageUuid: entry.messageUuid,
            createdAt: entry.createdAt,
            message: entry.message,
          } satisfies ArchivedHistoryRecord),
        );
      }
      if (lines.length === 0) return;

      // [A-8] Cheap bail-out before touching a directory we already know is
      // unusable, so a broken deployment does not pay the syscall (and the
      // log line) on every single trim.
      if (this.dirDisabled) return;

      this.ensureDir();
      appendFileSync(this.filePath(claudeSessionId), lines.join("\n") + "\n");
    } catch (err) {
      // Archiving is best-effort: a failure must never break a live turn.
      console.warn(
        `[history-archive] Failed to append for ${claudeSessionId}:`,
        err,
      );
    }
  }

  /**
   * Read archived records, filtered to a single bridge-session *segment*.
   *
   * `segment` semantics (A-6):
   *  - a string: only records archived by that exact bridge session are
   *    returned.  Histories from other runs are excluded even though they
   *    share `claudeSessionId` — their seq space is unrelated.
   *  - `undefined`: only *legacy untagged* records are returned (written before
   *    segment tagging existed, or by a caller with no segment).  Those are
   *    unambiguous by construction, so keeping them visible preserves the
   *    history of pre-upgrade runs without ever mixing two tagged spaces.
   *
   * When `maxSeq` is supplied, records below the in-memory window are returned
   * (the archive only ever receives trimmed entries, so the filter is a
   * belt-and-braces guard).  Ordering is ascending seq, which is a well-defined
   * order *within* one segment.
   */
  readUpTo(
    claudeSessionId: string,
    maxSeq?: number,
    segment?: string,
  ): ArchivedHistoryRecord[] {
    if (!claudeSessionId) return [];
    try {
      const path = this.filePath(claudeSessionId);
      if (!existsSync(path)) return [];
      const raw = readFileSync(path, "utf-8");
      if (!raw) return [];

      const out: ArchivedHistoryRecord[] = [];
      for (const line of raw.split("\n")) {
        if (!line) continue;
        try {
          const parsed = JSON.parse(line) as ArchivedHistoryRecord;
          if (typeof parsed?.seq !== "number") continue;
          if (parsed.segment !== segment) continue;
          if (typeof maxSeq === "number" && parsed.seq > maxSeq) continue;
          out.push(parsed);
        } catch {
          // skip malformed line
        }
      }
      out.sort((a, b) => a.seq - b.seq);
      return out;
    } catch (err) {
      console.warn(
        `[history-archive] Failed to read for ${claudeSessionId}:`,
        err,
      );
      return [];
    }
  }

  /** Drop tracking state for a session (session destroyed). */
  forget(claudeSessionId: string): void {
    this.seen.delete(claudeSessionId);
    this.loaded.delete(claudeSessionId);
  }

  /**
   * Rehydrate the dedupe key set from disk exactly once per session per process
   * so entries archived before a restart are not appended twice.
   */
  private ensureLoaded(claudeSessionId: string): void {
    if (this.loaded.has(claudeSessionId)) return;
    this.loaded.add(claudeSessionId);

    const keys = new Set<string>();
    this.seen.set(claudeSessionId, keys);

    const path = this.filePath(claudeSessionId);
    if (!existsSync(path)) return;
    try {
      const raw = readFileSync(path, "utf-8");
      for (const line of raw.split("\n")) {
        if (!line) continue;
        try {
          const parsed = JSON.parse(line) as ArchivedHistoryRecord;
          keys.add(archivedKey(parsed));
        } catch {
          // skip malformed line
        }
      }
    } catch {
      // ignore: treat as empty archive
    }
    if (keys.size > MAX_TRACKED_UUIDS) {
      // Extremely long session: keep memory bounded.  Worst case is a
      // duplicate line in the archive, which readers tolerate.
      //
      // [stable history ids · A-3] Keep the *newest* keys, not the oldest.
      // A `Set` iterates in insertion order and the file is append-only, so the
      // tail of the iteration is the most recently archived history — the part
      // a resuming client is most likely to ask for.  Keeping the head instead
      // would make the cap widen the dedupe window onto rows nobody replays.
      const all = [...keys];
      const trimmed = new Set<string>(all.slice(-MAX_TRACKED_UUIDS));
      this.seen.set(claudeSessionId, trimmed);
    }
  }

  /**
   * Create the archive directory once.
   *
   * [A-8] A persistent failure to create it is a stable property of the
   * deployment, not a transient hiccup: `dirReady` would otherwise stay false
   * and re-run the failing `mkdirSync` on every append.  Trip the breaker and
   * warn a single time instead.
   */
  private ensureDir(): void {
    if (this.dirReady) return;
    try {
      mkdirSync(this.resolveDir(), { recursive: true });
      this.dirReady = true;
    } catch (err) {
      this.dirDisabled = true;
      console.warn(
        `[history-archive] Archive directory unusable, disabling archiving for this process:`,
        err,
      );
    }
  }
}

function dedupeKey(entry: HistoryEntry): string {
  return entry.messageUuid ? `u:${entry.messageUuid}` : `s:${entry.seq}`;
}

function archivedKey(record: ArchivedHistoryRecord): string {
  return record.messageUuid ? `u:${record.messageUuid}` : `s:${record.seq}`;
}

/**
 * Keep session ids filesystem-safe (they are UUIDs in practice).
 *
 * Only `[A-Za-z0-9._-]` survive; dots are additionally collapsed so a crafted
 * session id such as `../../evil` can never produce a `..` path segment, escape
 * the archive directory, or land on a hidden file.
 *
 * [stable history ids · A-2] Length is capped as well: EXT4/NTFS reject file
 * names beyond 255 bytes with `ENAMETOOLONG`, which would turn every archive
 * write into a warning and silently disable the feature.  The cap leaves room
 * for the `.jsonl` suffix.
 */
function sanitize(id: string): string {
  const cleaned = id
    .replace(/[^A-Za-z0-9._-]/g, "_")
    .replace(/\.{2,}/g, "_")
    .replace(/^[._]+/, "_");
  const capped = cleaned.slice(0, MAX_SESSION_ID_LENGTH);
  return capped.length > 0 ? capped : "_";
}

/** Process-wide archive used by the session manager. */
export const historyArchive = new HistoryArchive();
