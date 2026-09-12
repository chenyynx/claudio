// 契约验证：对比能力关/开两种客户端拿到的 history_snapshot 差异
// 用法: node hist_probe_contract.cjs <sessionIdPrefix>
const fs = require("fs");
const path = require("path");

const WebSocket = (() => {
  for (const r of [
    path.join(process.env.HOME, "claudio/bridge/node_modules/ws"),
    path.join(process.env.HOME, "claudio/bridge/packages/bridge/node_modules/ws"),
  ]) {
    try { return require(r); } catch (e) {}
  }
  throw new Error("ws not found");
})();

function bridgeKey() {
  if (process.env.BRIDGE_API_KEY) return process.env.BRIDGE_API_KEY;
  for (const d of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(d)) continue;
    try {
      const raw = fs.readFileSync("/proc/" + d + "/environ", "utf8");
      for (const kv of raw.split("\0")) {
        if (kv.startsWith("BRIDGE_API_KEY=")) {
          return kv.slice("BRIDGE_API_KEY=".length);
        }
      }
    } catch (e) {}
  }
  throw new Error("BRIDGE_API_KEY not found");
}

const prefix = process.argv[2] || "";
const key = bridgeKey();
const port = process.env.BRIDGE_PORT || "8766";

function run(withCapability) {
  return new Promise(resolve => {
    const url = "ws://127.0.0.1:" + port + "/?token=" + encodeURIComponent(key);
    const ws = new WebSocket(url);
    const out = {
      mode: withCapability ? "capability ON" : "capability OFF",
    };
    const timer = setTimeout(() => {
      try { ws.close(); } catch (e) {}
      resolve(out);
    }, 8000);

    ws.on("open", () => {
      const declaration = {
        type: "client_capabilities",
        protocolVersion: 1,
        minimumProtocolVersion: 1,
      };
      if (withCapability) declaration.capabilities = ["stable_history_ids"];
      ws.send(JSON.stringify(declaration));
      ws.send(JSON.stringify({ type: "list_sessions" }));
    });

    ws.on("message", data => {
      let m;
      try { m = JSON.parse(data.toString()); } catch (e) { return; }

      if (m.type === "session_list") {
        out.bridgeCapabilities = m.protocolCapabilities;
        const hit = (m.sessions || []).find(s => String(s.id).startsWith(prefix));
        out.sessionId = hit ? hit.id : null;
        if (hit) {
          ws.send(JSON.stringify({
            type: "get_history_delta",
            sessionId: hit.id,
            sinceSeq: 0,
          }));
        }
      }

      if (m.type === "history_snapshot" || m.type === "history_delta") {
        const msgs = m.messages || [];
        out.frameType = m.type;
        out.reason = m.reason;
        out.fromSeq = m.fromSeq;
        out.toSeq = m.toSeq;
        out.entryCount = msgs.length;
        out.withAnyUuid = msgs.filter(
          x => x.message && (x.message.messageUuid || x.message.userMessageUuid),
        ).length;
        out.withEntryUuid = msgs.filter(x => x.messageUuid).length;
        out.withCreatedAt = msgs.filter(x => x.createdAt).length;
        clearTimeout(timer);
        try { ws.close(); } catch (e) {}
        resolve(out);
      }
    });

    ws.on("error", e => {
      out.error = e.message;
      clearTimeout(timer);
      resolve(out);
    });
  });
}

(async () => {
  const off = await run(false);
  const on = await run(true);
  console.log("=== A. 能力 OFF (legacy client) ===");
  console.log(JSON.stringify(off, null, 2));
  console.log("\n=== B. 能力 ON (stable_history_ids) ===");
  console.log(JSON.stringify(on, null, 2));
  console.log("\n=== 结论 ===");
  console.log("桥广播能力: " + JSON.stringify(off.bridgeCapabilities));
  console.log("OFF 条目数: " + off.entryCount + "   ON 条目数: " + on.entryCount);
  console.log("OFF entryUuid 覆盖: " + off.withEntryUuid + "   ON: " + on.withEntryUuid);
  console.log("OFF createdAt 覆盖: " + off.withCreatedAt + "   ON: " + on.withCreatedAt);
  process.exit(0);
})();
