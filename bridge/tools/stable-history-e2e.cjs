/**
 * [stable history ids] 端到端契约自检（在服务器上运行，独立于真实 CLI 会话）。
 *
 * 直接驱动编译产物 dist/ 的 SessionManager，验证：
 *   1. 每条 entry 都有 messageUuid + createdAt（B1）
 *   2. 能力 OFF 得到窗口快照、能力 ON 得到归档+窗口全量快照（B3/B3b）
 *   3. entry.messageUuid 与 message 上的 uuid 字段一致（B1 §4.0 取值链）
 *
 * 用法: node tools/stable-history-e2e.cjs
 */
const { mkdtempSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { randomUUID } = require("node:crypto");

const distDir = join(__dirname, "..", "packages", "bridge", "dist");
const { SessionManager } = require(join(distDir, "session.js"));

const archiveDir = mkdtempSync(join(tmpdir(), "stable-history-e2e-"));
process.env.CCPOCKET_HISTORY_ARCHIVE_DIR = archiveDir;

let failures = 0;
const check = (label, actual, expected) => {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`${ok ? "  PASS" : "  FAIL"}  ${label}: ${JSON.stringify(actual)}${ok ? "" : ` (expected ${JSON.stringify(expected)})`}`);
};
const checkTrue = (label, value) => {
  if (!value) failures++;
  console.log(`${value ? "  PASS" : "  FAIL"}  ${label}`);
};

console.log("=== 1. B1 稳定 id 注入 ===");
const manager = new SessionManager(() => {});
const sessionId = manager.create("/tmp/e2e-stable", undefined, undefined, undefined, "claude");
const session = manager.get(sessionId);
const claudeId = "claude-" + randomUUID();
session.claudeSessionId = claudeId;

const first = manager.appendHistory(sessionId, { type: "user_input", text: "hello" });
checkTrue("user_input entry 有 messageUuid", typeof first.messageUuid === "string" && first.messageUuid.length > 0);
checkTrue("user_input entry 有 createdAt", typeof first.createdAt === "string" && !Number.isNaN(Date.parse(first.createdAt)));

const assistantEntry = manager.appendHistory(sessionId, {
  type: "assistant",
  message: { id: "msg-1", role: "assistant", content: [{ type: "text", text: "hi" }], model: "test" },
  messageUuid: "transcript-uuid-1",
});
check("assistant entry 复用已有 messageUuid 字段", assistantEntry.messageUuid, "transcript-uuid-1");

const toolEntry = manager.appendHistory(sessionId, {
  type: "tool_result",
  toolUseId: "toolu_1",
  content: "ok",
  toolName: "Bash",
  userMessageUuid: "tool-uuid-1",
});
check("tool_result entry 复用 userMessageUuid", toolEntry.messageUuid, "tool-uuid-1");

console.log("\n=== 2. B1 无 uuid 帧的兜底与稳定性 ===");
const statusMsg = { type: "status", status: "idle" };
const s1 = manager.appendHistory(sessionId, statusMsg);
const s2 = manager.appendHistory(sessionId, statusMsg);
checkTrue("无 uuid 帧生成兜底 id", typeof s1.messageUuid === "string" && s1.messageUuid.length > 0);
check("同一 message 重复 append 的 id 稳定", s2.messageUuid, s1.messageUuid);

console.log("\n=== 3. B3/B3b 压缩快照：能力 OFF vs ON ===");
const manager2 = new SessionManager(() => {});
const sessionId2 = manager2.create("/tmp/e2e-snapshot", undefined, undefined, undefined, "claude");
manager2.get(sessionId2).claudeSessionId = "claude-" + randomUUID();
for (let i = 0; i < 130; i++) {
  manager2.appendHistory(sessionId2, { type: "status", status: i % 2 === 0 ? "running" : "idle" });
}

const off = manager2.getHistorySince(sessionId2, 0);
const on = manager2.getHistorySince(sessionId2, 0, { stableHistoryIds: true });

check("能力 OFF 的 kind", off.kind, "snapshot");
check("能力 OFF 的 reason", off.reason, "compacted");
check("能力 OFF 条目数（纯窗口）", off.entries.length, 100);
check("能力 ON 的 kind", on.kind, "snapshot");
check("能力 ON 的 reason", on.reason, "compacted");
checkTrue(`能力 ON 条目数(${on.entries.length}) > OFF(${off.entries.length})`, on.entries.length > off.entries.length);
checkTrue("能力 ON 起始 seq 早于 OFF", on.entries[0].seq < off.entries[0].seq);

console.log("\n=== 4. 快照条目身份完整性 ===");
const withUuid = on.entries.filter(e => typeof e.messageUuid === "string" && e.messageUuid).length;
const withCreatedAt = on.entries.filter(e => typeof e.createdAt === "string" && e.createdAt).length;
check("能力 ON 快照 messageUuid 全覆盖", withUuid, on.entries.length);
check("能力 ON 快照 createdAt 全覆盖", withCreatedAt, on.entries.length);
const uuids = on.entries.map(e => e.messageUuid);
check("messageUuid 无重复", new Set(uuids).size, uuids.length);

console.log("\n=== 5. 排序单调性 ===");
const seqs = on.entries.map(e => e.seq);
checkTrue("seq 严格递增", seqs.every((s, i) => i === 0 || s > seqs[i - 1]));
check("seq 覆盖范围", `${seqs[0]}..${seqs[seqs.length - 1]}`, `${on.fromSeq}..${on.toSeq}`);

console.log("\n=== 6. 游标在窗口内仍走增量 ===");
const cursor = seqs[seqs.length - 3];
const delta = manager2.getHistorySince(sessionId2, cursor, { stableHistoryIds: true });
check("窗口内游标的 kind", delta.kind, "delta");
check("增量条目数", delta.entries.length, 2);

console.log("\n=== 7. 无 claudeSessionId 时回退旧行为 ===");
const manager3 = new SessionManager(() => {});
const sessionId3 = manager3.create("/tmp/e2e-noclaude", undefined, undefined, undefined, "claude");
for (let i = 0; i < 130; i++) {
  manager3.appendHistory(sessionId3, { type: "status", status: "idle" });
}
const fallback = manager3.getHistorySince(sessionId3, 0, { stableHistoryIds: true });
check("无 claude id 时条目数回退为窗口大小", fallback.entries.length, 100);

rmSync(archiveDir, { recursive: true, force: true });

console.log(`\n=== 结果: ${failures === 0 ? "全部通过" : failures + " 项失败"} ===`);
process.exit(failures === 0 ? 0 : 1);
