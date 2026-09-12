// 只读取证：连本机桥 WS，拉会话历史，检查 seq / 稳定 id / 时间戳 / 重复
// 用法: node hist_probe.cjs <sessionIdPrefix>
//
// 本文件是 bridge/tools/ 下的诊断工具（read-only，不写桥状态）。
// v2 修订：修正 v1 的字段名误读 —— get_history_delta 应答帧的条目数组
//          wire 字段是 `messages`（见 websocket.ts get_history_delta handler），
//          v1 探测脚本检查的是 `delta.entries`，导致误判 "compacted 快照 entries=0"。
//          本版同时支持 `messages`（权威）与 `entries`（历史兼容探测）。
const fs = require("fs");
const path = require("path");

function loadWs() {
  const roots = [
    path.join(process.env.HOME, "claudio/bridge/node_modules/ws"),
    path.join(process.env.HOME, "claudio/bridge/packages/bridge/node_modules/ws"),
  ];
  for (const r of roots) {
    try { return require(r); } catch (e) {}
  }
  throw new Error("ws module not found");
}
const WebSocket = loadWs();

function bridgeKey() {
  // 首选环境变量；否则从桥进程 environ 里取（PID 会随重启变化，故命令行可覆盖）
  if (process.env.BRIDGE_API_KEY) return process.env.BRIDGE_API_KEY;
  const pid = process.env.BRIDGE_PID;
  const candidates = [];
  if (pid) candidates.push(`/proc/${pid}/environ`);
  // 兜底：扫描所有 node 进程的 environ 找 BRIDGE_API_KEY
  try {
    for (const d of fs.readdirSync("/proc")) {
      if (!/^\d+$/.test(d)) continue;
      candidates.push(`/proc/${d}/environ`);
    }
  } catch (e) {}
  for (const p of candidates) {
    try {
      const raw = fs.readFileSync(p, "utf8");
      for (const kv of raw.split("\0")) {
        if (kv.startsWith("BRIDGE_API_KEY=")) return kv.slice("BRIDGE_API_KEY=".length);
      }
    } catch (e) {}
  }
  throw new Error("BRIDGE_API_KEY not found (set env BRIDGE_API_KEY=... )");
}

const prefix = process.argv[2] || "";
const port = process.env.BRIDGE_PORT || "8766";
const key = bridgeKey();
const ws = new WebSocket(`ws://127.0.0.1:${port}/?token=${encodeURIComponent(key)}`);

const pending = [];
let done = false;
function send(o) { ws.send(JSON.stringify(o)); }

const timer = setTimeout(() => { console.log("TIMEOUT"); process.exit(2); }, 20000);

ws.on("open", () => { send({ type: "list_sessions" }); });

ws.on("message", (data) => {
  let m; try { m = JSON.parse(data.toString()); } catch (e) { return; }
  pending.push(m);
  if (m.type === "session_list" && !done) {
    done = true;
    const hit = (m.sessions || []).find(s => String(s.id).startsWith(prefix) || String(s.claudeSessionId||"").startsWith(prefix));
    if (!hit) {
      console.log("SESSION NOT FOUND by prefix", prefix);
      console.log("live sessions:", (m.sessions||[]).map(s => s.id + " claude=" + (s.claudeSessionId||"-")).join("\n  "));
      clearTimeout(timer); ws.close(); process.exit(1);
    }
    console.log("target session:", hit.id, "provider=" + hit.provider, "status=" + hit.status);
    // 能力广播检查（B3b 上线后应出现 stable_history_ids）
    if (hit.protocolCapabilities) {
      console.log("session protocolCapabilities:", JSON.stringify(hit.protocolCapabilities));
    } else {
      console.log("session protocolCapabilities: (none)");
    }
    send({ type: "get_history", sessionId: hit.id });
    send({ type: "get_history_delta", sessionId: hit.id, sinceSeq: 0 });
    setTimeout(() => { report(); }, 4000);
  }
});

// 条目数组取值：wire 权威字段是 `messages`
function frameEntries(frame) {
  if (!frame) return [];
  if (Array.isArray(frame.messages)) return frame.messages;
  if (Array.isArray(frame.entries)) return frame.entries; // 历史兼容
  return [];
}

function report() {
  const hist = pending.find(m => m.type === "history");
  const past = pending.find(m => m.type === "past_history");
  const delta = pending.find(m =>
    m.type === "history_delta" || m.type === "history_snapshot" ||
    ((m.type||"").startsWith("history_") && (Array.isArray(m.messages) || Array.isArray(m.entries)))
  );
  if (past) {
    console.log("\n=== past_history (磁盘回放) messages=" + (past.messages||[]).length + " ===");
    dump(past.messages, "past");
  }
  if (hist) {
    console.log("\n=== history (内存) messages=" + (hist.messages||[]).length + " ===");
    dump(hist.messages, "mem");
  }
  if (delta) {
    const entries = frameEntries(delta);
    console.log("\n=== delta frame type=" + delta.type + " kind=" + (delta.kind || "-")
      + " fromSeq=" + delta.fromSeq + " toSeq=" + delta.toSeq
      + " entries(messages)=" + entries.length + " reason=" + (delta.reason || "-") + " ===");
    // 稳定 id / 时间戳覆盖统计（B1 上线后应 100%）
    let withUuid = 0, withTs = 0;
    for (const e of entries) {
      const msg = e.message || {};
      const uuid = msg.userMessageUuid || msg.messageUuid || e.messageUuid;
      const ts = msg.timestamp || e.createdAt;
      if (uuid) withUuid++;
      if (ts) withTs++;
    }
    console.log(`  entry 稳定 id 覆盖: ${withUuid}/${entries.length}   时间戳覆盖: ${withTs}/${entries.length}`);
    for (const e of entries.slice(0, 10)) {
      const msg = e.message || {};
      const uuid = msg.userMessageUuid || msg.messageUuid || e.messageUuid || "-";
      const ts = msg.timestamp || e.createdAt || "NONE";
      console.log("  seq=" + e.seq, "entryUuid=" + String(e.messageUuid||"-").slice(0,8),
        "type=" + msg.type, "msgUuid=" + String(uuid).slice(0,8), "ts=" + ts);
    }
  } else {
    console.log("\n[!] 未收到 history_delta / history_snapshot 帧；收到的帧类型: "
      + [...new Set(pending.map(m => m.type))].join(", "));
  }
  clearTimeout(timer); ws.close(); process.exit(0);
}

function dump(msgs, tag) {
  const seen = {};
  let ui = 0;
  for (const m of msgs) {
    const t = m.type || "?";
    if (t === "user_input") ui++;
    const ts = m.timestamp || m.createdAt || m.time;
    const hasTs = ts ? "TS" : "no-ts";
    const uuid = m.userMessageUuid || m.messageUuid || "-";
    const txt = typeof m.text === "string" ? m.text : (typeof m.content === "string" ? m.content : "");
    const line = `${tag} type=${t.padEnd(14)} seq=${String(m.historySeq ?? "-").padEnd(5)} ${hasTs.padEnd(6)} uuid=${String(uuid).slice(0,8)} cmlId=${(m.clientMessageId||"-").toString().slice(0,8)} text="${txt.replace(/\n/g," ").slice(0,42)}"`;
    seen[line] = (seen[line] || 0) + 1;
    if (seen[line] === 1) console.log("  " + line);
    else seen["__dup"] = (seen["__dup"]||0)+1;
  }
  console.log(`  [${tag}] user_input total=${ui}  dupLines=${seen["__dup"]||0}`);
  const withTs = msgs.filter(m => m.timestamp || m.createdAt || m.time).length;
  const withUuid = msgs.filter(m => m.userMessageUuid || m.messageUuid).length;
  console.log(`  [${tag}] msgs with timestamp: ${withTs}/${msgs.length}   with stable uuid: ${withUuid}/${msgs.length}`);
}

ws.on("error", (e) => { console.log("WS ERROR:", e.message); process.exit(3); });
