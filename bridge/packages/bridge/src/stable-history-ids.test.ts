import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { join } from "node:path";
import { homedir } from "node:os";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProcessStatus, ServerMessage } from "./parser.js";
import { pathToSlug } from "./sessions-index.js";

/**
 * [stable history ids] Bridge-side tests for B1 (entry identity injection),
 * B1b (uuid backfill across all three message kinds) and B3 (archive-backed
 * full-history snapshot).
 *
 * The fs module is mocked the same way session.test.ts does it, so these tests
 * never touch the real ~/.claude or ~/.ccpocket directories.  The archive is
 * redirected with CCPOCKET_HISTORY_ARCHIVE_DIR.
 */
const { sdkInstances, fakeDirs, fakeFiles } = vi.hoisted(() => ({
  sdkInstances: [] as Array<{
    permissionMode: string;
    start: ReturnType<typeof vi.fn>;
    stop: ReturnType<typeof vi.fn>;
    rewindFiles: ReturnType<typeof vi.fn>;
    emit: (event: string, ...args: unknown[]) => boolean;
  }>,
  fakeDirs: new Set<string>(),
  fakeFiles: new Map<string, string>(),
}));

vi.mock("node:fs", async importOriginal => {
  const actual = await importOriginal<typeof import("node:fs")>();
  const normalize = (value: unknown): string =>
    String(value).replaceAll("\\", "/");
  return {
    ...actual,
    // Only the Claude transcript path is virtualized; the archive layer keeps
    // using the real fs against a temporary directory.
    existsSync: vi.fn((path: unknown) => {
      const key = normalize(path);
      if (fakeDirs.has(key) || fakeFiles.has(key)) return true;
      return actual.existsSync(path as string);
    }),
    readFileSync: vi.fn((path: unknown, ...rest: unknown[]) => {
      const key = normalize(path);
      const content = fakeFiles.get(key);
      if (content != null) return content;
      return (actual.readFileSync as (...a: unknown[]) => unknown)(
        path,
        ...rest,
      );
    }),
    readdirSync: vi.fn(
      (path: unknown, options?: { withFileTypes?: boolean }) => {
        const base = normalize(path);
        const prefix = base.endsWith("/") ? base : `${base}/`;
        const childNames = new Set<string>();
        for (const dir of fakeDirs) {
          if (!dir.startsWith(prefix)) continue;
          const rest = dir.slice(prefix.length);
          if (!rest || rest.includes("/")) continue;
          childNames.add(rest);
        }
        if (childNames.size > 0) {
          if (options?.withFileTypes) {
            return [...childNames].map(name => ({
              name,
              isDirectory: () => true,
            }));
          }
          return [...childNames];
        }
        return (actual.readdirSync as (...a: unknown[]) => unknown)(
          path,
          options,
        );
      },
    ),
  };
});

vi.mock("./sdk-process.js", () => ({
  SdkProcess: class MockSdkProcess extends EventEmitter {
    public permissionMode = "default";
    public start = vi.fn((_: string, __?: unknown) => {});
    public stop = vi.fn(() => {});
    public rewindFiles = vi.fn(async () => ({ canRewind: false }));

    constructor() {
      super();
      sdkInstances.push(this);
    }
  },
}));

vi.mock("./codex-process.js", () => ({
  normalizeCodexReasoningEffortForModel: (
    _model: unknown,
    effort: string | undefined,
  ) => effort,
  CodexProcess: class MockCodexProcess extends EventEmitter {
    public isWaitingForInput = false;
    public start = vi.fn();
    public stop = vi.fn();
    public sendInputStructured = vi.fn();
    public steerInputStructured = vi.fn(async () => {});
  },
}));

import { HistoryArchive } from "./history-archive.js";
import { SessionManager } from "./session.js";

const registerHistoryJsonl = (
  projectLikePath: string,
  threadId: string,
  lines: string[],
): void => {
  const projectsDir = join(homedir(), ".claude", "projects");
  const dir = join(projectsDir, pathToSlug(projectLikePath));
  fakeDirs.add(projectsDir);
  fakeDirs.add(dir);
  fakeFiles.set(join(dir, `${threadId}.jsonl`), `${lines.join("\n")}\n`);
};

describe("stable history ids · B1 entry identity", () => {
  beforeEach(() => {
    sdkInstances.length = 0;
    fakeDirs.clear();
    fakeFiles.clear();
    process.env.CCPOCKET_HISTORY_ARCHIVE_DIR = join(
      homedir(),
      `.ccpocket-test-${randomUUID()}`,
    );
  });

  it("assigns every entry a stable messageUuid and createdAt", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-ids-b1");

    const status = manager.appendHistory(sessionId, {
      type: "status",
      status: "running",
    } as ServerMessage);

    expect(status?.messageUuid).toBeTruthy();
    expect(typeof status?.messageUuid).toBe("string");
    expect(status?.createdAt).toBeTruthy();
    expect(Number.isNaN(Date.parse(status!.createdAt!))).toBe(false);
  });

  it("reuses the assistant frame uuid as the entry identity (no new field name)", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-ids-b1-assistant");

    const entry = manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "msg-abc",
        role: "assistant",
        content: [{ type: "text", text: "hi" }],
        model: "test",
      },
      messageUuid: "transcript-uuid-1",
    } as ServerMessage);

    expect(entry?.messageUuid).toBe("transcript-uuid-1");
  });

  it("falls back to the assistant message id when no uuid is present", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-ids-b1-fallback");

    const entry = manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "msg-only-id",
        role: "assistant",
        content: [{ type: "text", text: "hi" }],
        model: "test",
      },
    } as ServerMessage);

    expect(entry?.messageUuid).toBe("msg-only-id");
  });

  it("reuses the user_input frame uuid when already present", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-ids-b1-user");

    const entry = manager.appendHistory(sessionId, {
      type: "user_input",
      text: "hello",
      userMessageUuid: "user-uuid-1",
    } as ServerMessage);

    expect(entry?.messageUuid).toBe("user-uuid-1");
  });

  it("keeps the generated uuid stable across repeated appends of one message", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-ids-b1-repeat");

    const msg = { type: "status", status: "idle" } as ServerMessage;
    const first = manager.appendHistory(sessionId, msg);
    const second = manager.appendHistory(sessionId, msg);

    expect(first?.messageUuid).toBeTruthy();
    expect(second?.messageUuid).toBe(first?.messageUuid);
  });

  it("preserves an explicit timestamp from the message", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-ids-b1-ts");

    const entry = manager.appendHistory(sessionId, {
      type: "user_input",
      text: "hi",
      timestamp: "2026-09-12T10:00:00.000Z",
    } as ServerMessage);

    expect(entry?.createdAt).toBe("2026-09-12T10:00:00.000Z");
  });

  it("exposes messageUuid on delta entries", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-ids-b1-delta");

    manager.appendHistory(sessionId, {
      type: "status",
      status: "running",
    } as ServerMessage);
    const second = manager.appendHistory(sessionId, {
      type: "user_input",
      text: "hello",
    } as ServerMessage);

    const result = manager.getHistorySince(sessionId, 0);
    expect(result?.kind).toBe("delta");
    expect(result?.entries.at(-1)?.messageUuid).toBe(second?.messageUuid);
  });
});

describe("stable history ids · B1b uuid backfill for all message kinds", () => {
  let archiveDir: string;

  beforeEach(() => {
    sdkInstances.length = 0;
    fakeDirs.clear();
    fakeFiles.clear();
    archiveDir = join(homedir(), `.ccpocket-test-${randomUUID()}`);
    process.env.CCPOCKET_HISTORY_ARCHIVE_DIR = archiveDir;
  });

  it("backfills user text uuids in order of occurrence", () => {
    const testId = randomUUID();
    const projectPath = `/tmp/backfill-all-${testId}`;
    const threadId = `thread-${testId}`;
    registerHistoryJsonl(projectPath, threadId, [
      JSON.stringify({
        type: "user",
        uuid: "user-a",
        message: { content: [{ type: "text", text: "在吗" }] },
      }),
      JSON.stringify({
        type: "user",
        uuid: "user-b",
        message: { content: [{ type: "text", text: "在吗" }] },
      }),
    ]);

    const manager = new SessionManager(() => {});
    const sessionId = manager.create(projectPath, undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = threadId;

    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "在吗",
    } as ServerMessage);
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "在吗",
    } as ServerMessage);

    sdkInstances[0].emit("message", {
      type: "result",
      subtype: "success",
      sessionId: threadId,
    } satisfies ServerMessage);

    const uuids = session.history
      .filter(m => m.type === "user_input")
      .map(m => (m as { userMessageUuid?: string }).userMessageUuid);
    expect(uuids).toEqual(["user-a", "user-b"]);
  });

  it("backfills assistant messageUuid and keeps entry identity in sync", () => {
    const testId = randomUUID();
    const projectPath = `/tmp/backfill-assistant-${testId}`;
    const threadId = `thread-${testId}`;
    registerHistoryJsonl(projectPath, threadId, [
      JSON.stringify({
        type: "assistant",
        uuid: "assistant-uuid-1",
        message: {
          id: "msg-1",
          content: [{ type: "text", text: "hello" }],
        },
      }),
    ]);

    const manager = new SessionManager(() => {});
    const sessionId = manager.create(projectPath, undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = threadId;

    // assistant arrives without a uuid yet (live path).
    const entry = manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "msg-1",
        role: "assistant",
        content: [{ type: "text", text: "hello" }],
        model: "test",
      },
    } as ServerMessage);
    const generated = entry?.messageUuid;
    expect(generated).toBeTruthy();

    sdkInstances[0].emit("message", {
      type: "result",
      subtype: "success",
      sessionId: threadId,
    } satisfies ServerMessage);

    const assistant = session.history.find(m => m.type === "assistant");
    expect((assistant as { messageUuid?: string }).messageUuid).toBe(
      "assistant-uuid-1",
    );
    // The entry identity is rewritten to the transcript uuid.
    expect(entry?.messageUuid).toBe("assistant-uuid-1");
  });

  it("backfills tool_result uuids by pairing tool_use ids", () => {
    const testId = randomUUID();
    const projectPath = `/tmp/backfill-tool-${testId}`;
    const threadId = `thread-${testId}`;
    registerHistoryJsonl(projectPath, threadId, [
      JSON.stringify({
        type: "assistant",
        uuid: "assistant-uuid-1",
        message: {
          id: "msg-1",
          content: [
            { type: "tool_use", id: "toolu_1", name: "Bash", input: {} },
          ],
        },
      }),
      JSON.stringify({
        type: "tool_result",
        uuid: "toolresult-uuid-1",
        message: { content: [{ type: "text", text: "ok" }] },
      }),
    ]);

    const manager = new SessionManager(() => {});
    const sessionId = manager.create(projectPath, undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = threadId;

    manager.appendHistory(sessionId, {
      type: "tool_result",
      toolUseId: "toolu_1",
      content: "ok",
      toolName: "Bash",
    } as ServerMessage);

    sdkInstances[0].emit("message", {
      type: "result",
      subtype: "success",
      sessionId: threadId,
    } satisfies ServerMessage);

    const toolResult = session.history.find(m => m.type === "tool_result") as
      | { userMessageUuid?: string }
      | undefined;
    expect(toolResult?.userMessageUuid).toBe("toolresult-uuid-1");
  });

  it("leaves rows untouched when the transcript is unavailable", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/backfill-missing", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = "no-such-thread";

    const entry = manager.appendHistory(sessionId, {
      type: "user_input",
      text: "hi",
    } as ServerMessage);

    sdkInstances[0].emit("message", {
      type: "result",
      subtype: "success",
      sessionId: "no-such-thread",
    } satisfies ServerMessage);

    expect((session.history[0] as { userMessageUuid?: string }).userMessageUuid)
      .toBeUndefined();
    // Identity still exists (generated), so ordering stays stable.
    expect(entry?.messageUuid).toBeTruthy();
  });
});

describe("stable history ids · B3 archive-backed snapshot", () => {
  let archiveDir: string;

  beforeEach(() => {
    sdkInstances.length = 0;
    fakeDirs.clear();
    fakeFiles.clear();
    archiveDir = join(homedir(), `.ccpocket-test-${randomUUID()}`);
    process.env.CCPOCKET_HISTORY_ARCHIVE_DIR = archiveDir;
  });

  /**
   * Fill the window past MAX (100) so entries are trimmed into the archive.
   *
   * NOTE on the sequence base: `SessionManager.create()` itself appends one
   * entry (seq 1) before the caller can assign `claudeSessionId`, so that first
   * row can never be archived. Tests therefore assert on the *append* range,
   * not on absolute seq values starting at 1.
   */
  const overfill = (manager: SessionManager, sessionId: string, count: number) => {
    for (let i = 0; i < count; i++) {
      manager.appendHistory(sessionId, {
        type: "status",
        status: i % 2 === 0 ? "running" : "idle",
      } as ServerMessage);
    }
  };

  it("keeps legacy (capability-off) snapshot semantics unchanged", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-b3-off", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = `claude-${randomUUID()}`;

    overfill(manager, sessionId, 105);

    const result = manager.getHistorySince(sessionId, 0);
    expect(result?.kind).toBe("snapshot");
    expect(result?.entries).toHaveLength(100);
    expect(result?.entries[0].seq).toBe(6);
    if (result?.kind === "snapshot") expect(result.reason).toBe("compacted");
  });

  it("serves archive + window for capability-on clients", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-b3-on", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = `claude-${randomUUID()}`;

    overfill(manager, sessionId, 105);

    const result = manager.getHistorySince(sessionId, 0, {
      stableHistoryIds: true,
    });
    expect(result?.kind).toBe("snapshot");
    // Measured: 105 appends (seq 2..106 alongside create()'s seq 1) leave the
    // window holding seq 7..106 and the archive holding 2..6. `create()`'s
    // initial row (seq 1) predates the id assignment and stays unrecoverable.
    expect(result?.entries).toHaveLength(104);
    expect(result?.entries[0].seq).toBe(2);
    expect(result?.entries.at(-1)?.seq).toBe(105);
    // Crucially, far more than the legacy window-only 100.
    expect(result!.entries.length).toBeGreaterThan(100);
  });

  it("returns entries in ascending seq order with unique identities", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-b3-order", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = `claude-${randomUUID()}`;

    overfill(manager, sessionId, 130);

    const result = manager.getHistorySince(sessionId, 0, {
      stableHistoryIds: true,
    });
    const entries = result?.entries ?? [];
    // Measured: 130 appends yield 129 recoverable entries (seq 1, written by
    // create() before claudeSessionId existed, is unrecoverable) — 29 more than
    // the legacy window-only snapshot would return.
    expect(entries).toHaveLength(129);

    const seqs = entries.map(e => e.seq);
    expect([...seqs].sort((a, b) => a - b)).toEqual(seqs);

    const uuids = entries.map(e => e.messageUuid).filter(Boolean);
    expect(new Set(uuids).size).toBe(uuids.length);
  });

  it("falls back to the window snapshot when nothing was archived yet", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-b3-none", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = `claude-${randomUUID()}`;

    // Never crosses the window, so the archive stays empty.
    overfill(manager, sessionId, 10);

    const result = manager.getHistorySince(sessionId, 0, {
      stableHistoryIds: true,
    });
    // Cursor 0 is above the low watermark here, so this is a plain delta.
    expect(result?.kind).toBe("delta");
    expect(result?.entries).toHaveLength(10);
  });

  it("does not consult the archive for a session without a claude id", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-b3-noclae", undefined, undefined, undefined, "claude");

    overfill(manager, sessionId, 105);

    const result = manager.getHistorySince(sessionId, 0, {
      stableHistoryIds: true,
    });
    // No claudeSessionId => nothing archived => legacy window snapshot.
    expect(result?.entries).toHaveLength(100);
    expect(result?.entries[0].seq).toBe(6);
  });

  it("serves deltas normally when the cursor is inside the window", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-b3-delta", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = `claude-${randomUUID()}`;

    overfill(manager, sessionId, 105);
    const cursor = session.historyEntries.at(-1)!.seq - 2;

    const result = manager.getHistorySince(sessionId, cursor, {
      stableHistoryIds: true,
    });
    expect(result?.kind).toBe("delta");
    expect(result?.entries).toHaveLength(2);
    expect(result?.entries.every(e => e.seq > cursor)).toBe(true);
  });
});

describe("stable history ids · independent archive instance", () => {
  let archiveDir: string;

  beforeEach(() => {
    // Set the archive dir *before* the module-level singleton is used so both
    // the SessionManager and the standalone reader agree on the location.
    archiveDir = join(homedir(), `.ccpocket-test-${randomUUID()}`);
    process.env.CCPOCKET_HISTORY_ARCHIVE_DIR = archiveDir;
  });

  it("archives through the singleton SessionManager writes to", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/stable-singleton", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    const claudeId = `claude-${randomUUID()}`;
    session.claudeSessionId = claudeId;

    for (let i = 0; i < 105; i++) {
      manager.appendHistory(sessionId, {
        type: "status",
        status: "idle",
      } as ServerMessage);
    }

    // Read through a fresh instance so the assertion does not depend on
    // whatever dedupe state earlier tests left in the process-wide singleton.
    const records = new HistoryArchive(archiveDir).readUpTo(
      claudeId,
      999,
      manager.get(sessionId)!.bridgeSegment,
    );

    // The property that matters: rows trimmed out of the 100-entry window are
    // still retrievable.  `create()`'s initial row (seq 1) precedes the id
    // assignment and is unrecoverable, so we expect the rows that were trimmed
    // while a claudeSessionId was known.
    expect(records.length).toBeGreaterThanOrEqual(4);
    expect(records.every(r => r.messageUuid)).toBe(true);
    const seqs = records.map(r => r.seq);
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
    // Contiguous run right after the unrecoverable seq 1, ending at the
    // window's low watermark minus one.
    expect(seqs[0]).toBe(2);
    expect(seqs.at(-1)).toBe(session.historyEntries[0].seq - 1);
  });
});


/**
 * [stable history ids · A-6] Segment isolation.
 *
 * The archive file is keyed by `claudeSessionId`, which is shared by every
 * bridge session resuming the same Claude transcript — but `seq` is
 * per-bridge-session and restarts at 0 on `create()`.  Before segment tagging,
 * two runs' seq spaces were spliced together, so a resuming client received an
 * interleaved snapshot (seq `1,2,2,3,3,…`) containing another run's messages —
 * which is precisely the out-of-order/duplicate rendering this batch fixes.
 *
 * Reproduction: two `SessionManager`s (two bridge sessions) pointed at the same
 * `claudeSessionId`, each overfilling the window so rows are archived.
 */
describe("stable history ids · A-6 archive segment isolation", () => {
  let archiveDir: string;

  beforeEach(() => {
    sdkInstances.length = 0;
    fakeDirs.clear();
    fakeFiles.clear();
    archiveDir = join(homedir(), `.ccpocket-test-${randomUUID()}`);
    process.env.CCPOCKET_HISTORY_ARCHIVE_DIR = archiveDir;
  });

  const overfill = (
    manager: SessionManager,
    sessionId: string,
    count: number,
  ) => {
    for (let i = 0; i < count; i++) {
      manager.appendHistory(sessionId, {
        type: "status",
        status: i % 2 === 0 ? "running" : "idle",
      } as ServerMessage);
    }
  };

  it("gives every bridge session its own segment id", () => {
    const manager = new SessionManager(() => {});
    const a = manager.create("/tmp/a6-seg-a", undefined, undefined, undefined, "claude");
    const b = manager.create("/tmp/a6-seg-b", undefined, undefined, undefined, "claude");

    const segA = manager.get(a)!.bridgeSegment;
    const segB = manager.get(b)!.bridgeSegment;

    expect(segA).toBeTruthy();
    expect(segB).toBeTruthy();
    expect(segA).not.toBe(segB);
  });

  it("does not splice another bridge session's history into the snapshot", () => {
    const sharedClaudeId = `claude-${randomUUID()}`;

    // Run A archives a full window against the shared claude session id.
    const managerA = new SessionManager(() => {});
    const idA = managerA.create("/tmp/a6-pollute-a", undefined, undefined, undefined, "claude");
    managerA.get(idA)!.claudeSessionId = sharedClaudeId;
    overfill(managerA, idA, 130);

    const aEntries = managerA.getHistorySince(idA, 0, {
      stableHistoryIds: true,
    })!;
    const aUuids = new Set(aEntries.entries.map(e => e.messageUuid));

    // Run B resumes the SAME Claude transcript in a fresh bridge session.
    const managerB = new SessionManager(() => {});
    const idB = managerB.create("/tmp/a6-pollute-b", undefined, undefined, undefined, "claude");
    managerB.get(idB)!.claudeSessionId = sharedClaudeId;
    overfill(managerB, idB, 130);

    const bEntries = managerB.getHistorySince(idB, 0, {
      stableHistoryIds: true,
    })!;

    // B's own window only — never A's archived tail spliced in.
    // (130 appends leave the window holding 100; everything above that is B's
    // own archive. The pre-fix bug returned 161 rows here.)
    expect(bEntries.entries.length).toBeGreaterThanOrEqual(100);
    expect(bEntries.entries.length).toBeLessThan(140);

    // No row may carry a uuid that only exists in A's run.
    const bUuids = bEntries.entries.map(e => e.messageUuid).filter(Boolean);
    for (const uuid of bUuids) {
      expect(aUuids.has(uuid)).toBe(false);
    }

    // And no seq may repeat: a repeated seq is the signature of two seq spaces
    // being interleaved (the pre-fix bug).
    const seqs = bEntries.entries.map(e => e.seq);
    expect(new Set(seqs).size).toBe(seqs.length);
  });

  it("still serves rows archived by the same bridge session", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/a6-same-seg", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = `claude-${randomUUID()}`;

    overfill(manager, sessionId, 130);

    const result = manager.getHistorySince(sessionId, 0, {
      stableHistoryIds: true,
    })!;
    // Segment filtering must not drop the session's own archive.
    expect(result.entries).toHaveLength(129);
    expect(result.entries[0].seq).toBe(2);
  });

  it("keeps legacy untagged records visible after an upgrade", () => {
    const claudeId = `claude-${randomUUID()}`;
    // Simulate a pre-upgrade archive: untagged records written by the old code.
    const legacy = new HistoryArchive(archiveDir);
    legacy.append(claudeId, [
      { seq: 1, message: { type: "status", status: "idle" } as ServerMessage, messageUuid: "legacy-1" },
      { seq: 2, message: { type: "status", status: "idle" } as ServerMessage, messageUuid: "legacy-2" },
    ]);

    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/a6-legacy", undefined, undefined, undefined, "claude");
    const session = manager.get(sessionId)!;
    session.claudeSessionId = claudeId;

    overfill(manager, sessionId, 130);

    const result = manager.getHistorySince(sessionId, 0, {
      stableHistoryIds: true,
    })!;
    const uuids = result.entries.map(e => e.messageUuid);
    expect(uuids).toContain("legacy-1");
    expect(uuids).toContain("legacy-2");
  });

  it("readUpTo filters by segment and treats undefined as legacy-only", () => {
    const claudeId = `claude-${randomUUID()}`;
    const archive = new HistoryArchive(archiveDir);
    const mk = (seq: number, uuid: string) => ({
      seq,
      message: { type: "status", status: "idle" } as ServerMessage,
      messageUuid: uuid,
    });

    archive.append(claudeId, [mk(1, "seg-a-1")], "seg-a");
    archive.append(claudeId, [mk(2, "seg-b-1")], "seg-b");
    archive.append(claudeId, [mk(3, "legacy-1")]);

    expect(archive.readUpTo(claudeId, undefined, "seg-a").map(r => r.messageUuid)).toEqual(["seg-a-1"]);
    expect(archive.readUpTo(claudeId, undefined, "seg-b").map(r => r.messageUuid)).toEqual(["seg-b-1"]);
    expect(archive.readUpTo(claudeId, undefined, undefined).map(r => r.messageUuid)).toEqual(["legacy-1"]);

    // A segment read with a maxSeq caps the range within that segment.
    expect(archive.readUpTo(claudeId, 2, "seg-a")).toHaveLength(1);
    // Legacy reads DO still honour maxSeq (it filters all records uniformly);
    // the legacy row in this fixture has seq 3, so it is excluded at maxSeq 2
    // and included unbounded.
    expect(archive.readUpTo(claudeId, 2, undefined)).toEqual([]);
    expect(archive.readUpTo(claudeId, 3, undefined)).toHaveLength(1);
  });
});

/**
 * [stable history ids · A-7] Merge keeps entry identity in sync.
 *
 * The SDK does not echo user messages, so a freshly appended `user_input` has
 * no uuid and gets a bridge placeholder.  A later echo/merge supplies the real
 * `userMessageUuid` — the same value the client used for its optimistic live
 * row (`bm-<clientMessageId>`).  If `entry.messageUuid` is not updated to that
 * real value, the full-history row and the live row look like different
 * messages and the turn renders twice.
 *
 * These tests drive the *production* merge path (`processMessage`, reached by
 * emitting on the mock process) rather than the direct `appendHistory` helper,
 * because only `processMessage` performs the merge.
 */
describe("stable history ids · A-7 merge syncs entry identity", () => {
  let archiveDir: string;

  beforeEach(() => {
    sdkInstances.length = 0;
    fakeDirs.clear();
    fakeFiles.clear();
    archiveDir = join(homedir(), `.ccpocket-test-${randomUUID()}`);
    process.env.CCPOCKET_HISTORY_ARCHIVE_DIR = archiveDir;
  });

  /** Deliver a message through the real process pipeline. */
  const deliver = async (msg: ServerMessage): Promise<void> => {
    const proc = sdkInstances.at(-1)!;
    proc.emit("message", msg);
    // processMessage is invoked via `void processMessage(msg)`; let the
    // microtask queue drain so the history mutation is observable.
    await new Promise(resolve => setTimeout(resolve, 0));
  };

  const userEntries = (manager: SessionManager, sessionId: string) =>
    manager.get(sessionId)!.historyEntries.filter(
      e => e.message.type === "user_input",
    );

  it("adopts the real userMessageUuid supplied by a later merge", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/a7-merge", undefined, undefined, undefined, "claude");

    // 1. The SDK echoes the optimistic turn without a uuid: placeholder identity.
    await deliver({ type: "user_input", text: "hello world" } as ServerMessage);
    const placeholder = userEntries(manager, sessionId)[0]?.messageUuid;
    expect(placeholder).toBeTruthy();

    // 2. The real echo arrives (same text) carrying the client's uuid.
    await deliver({
      type: "user_input",
      text: "hello world",
      userMessageUuid: "CID-REAL",
    } as ServerMessage);

    // Merged into the same row: still one entry.
    const entries = userEntries(manager, sessionId);
    expect(entries).toHaveLength(1);

    // Identity followed the message: the real uuid, not the placeholder.
    expect(entries[0].messageUuid).toBe("CID-REAL");
    expect(entries[0].messageUuid).not.toBe(placeholder);
    expect(entries[0].message.userMessageUuid).toBe("CID-REAL");
  });

  it("keeps the real uuid stable across repeated merges", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/a7-merge-stable", undefined, undefined, undefined, "claude");

    await deliver({ type: "user_input", text: "same text" } as ServerMessage);
    await deliver({
      type: "user_input",
      text: "same text",
      userMessageUuid: "CID-STABLE",
    } as ServerMessage);
    // Re-delivery of the same echo must not regenerate a placeholder.
    await deliver({
      type: "user_input",
      text: "same text",
      userMessageUuid: "CID-STABLE",
    } as ServerMessage);

    const entries = userEntries(manager, sessionId);
    expect(entries).toHaveLength(1);
    expect(entries[0].messageUuid).toBe("CID-STABLE");
  });

  it("keeps a stable placeholder when no real uuid ever arrives", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/a7-placeholder", undefined, undefined, undefined, "claude");

    await deliver({ type: "user_input", text: "no echo yet" } as ServerMessage);
    const first = userEntries(manager, sessionId)[0]?.messageUuid;

    await deliver({ type: "user_input", text: "no echo yet" } as ServerMessage);
    const entries = userEntries(manager, sessionId);

    expect(entries).toHaveLength(1);
    // Repeated merges (with no real uuid anywhere) must not churn the identity,
    // otherwise every resume would look like a brand-new message.
    expect(entries[0].messageUuid).toBe(first);
  });

  it("prefers the real uuid whichever side of the merge carries it", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/a7-both-sides", undefined, undefined, undefined, "claude");

    // First row already has a real uuid, the echo does not.
    await deliver({
      type: "user_input",
      text: "with uuid first",
      userMessageUuid: "CID-FIRST",
    } as ServerMessage);
    await deliver({ type: "user_input", text: "with uuid first" } as ServerMessage);

    const entries = userEntries(manager, sessionId);
    expect(entries).toHaveLength(1);
    expect(entries[0].messageUuid).toBe("CID-FIRST");
  });

  it("keeps live-row and history-row identity aligned (bm- agreement)", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/a7-live-align", undefined, undefined, undefined, "claude");

    // The client sent this turn with clientMessageId = CID-LIVE; websocket.ts
    // mirrors it into userMessageUuid on the outgoing frame.
    await deliver({
      type: "user_input",
      text: "aligned turn",
      userMessageUuid: "CID-LIVE",
      clientMessageId: "CID-LIVE",
    } as ServerMessage);

    const entries = userEntries(manager, sessionId);
    expect(entries).toHaveLength(1);
    // Both the identity and the wire field agree, so the client keys the live
    // row and the history row on the same `bm-CID-LIVE`.
    expect(entries[0].messageUuid).toBe("CID-LIVE");
    expect(entries[0].message.userMessageUuid).toBe("CID-LIVE");
  });
});
