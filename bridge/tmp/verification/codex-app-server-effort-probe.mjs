import { mkdirSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";

const outDir = new URL("./", import.meta.url);
const cwd = process.argv[2]
  ?? "/Users/k9i-mini/Workspace/ccpocket/tmp/verification/issue54-path";
const efforts = ["high", "xhigh"];

mkdirSync(outDir, { recursive: true });

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runProbe(effort) {
  const child = spawn("codex", ["app-server", "--listen", "stdio://"], {
    cwd,
    stdio: ["pipe", "pipe", "pipe"],
    env: process.env,
  });

  const transcript = {
    effort,
    cwd,
    startedAt: new Date().toISOString(),
    stdout: [],
    stderr: [],
    requests: [],
    responses: [],
    notifications: [],
  };

  let seq = 1;
  let stdoutBuffer = "";
  const pending = new Map();

  const send = (method, params) => {
    const id = seq++;
    const envelope = { id, method, params };
    transcript.requests.push(envelope);
    child.stdin.write(`${JSON.stringify(envelope)}\n`);
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject, method });
    });
  };

  const settleError = (error) => {
    for (const { reject } of pending.values()) {
      reject(error);
    }
    pending.clear();
  };

  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    while (true) {
      const nl = stdoutBuffer.indexOf("\n");
      if (nl === -1) break;
      const line = stdoutBuffer.slice(0, nl).trim();
      stdoutBuffer = stdoutBuffer.slice(nl + 1);
      if (!line) continue;
      let parsed;
      try {
        parsed = JSON.parse(line);
      } catch {
        transcript.stdout.push({ raw: line });
        continue;
      }
      if (parsed.id !== undefined) {
        transcript.responses.push(parsed);
        const pendingEntry = pending.get(parsed.id);
        if (pendingEntry) {
          pending.delete(parsed.id);
          if (parsed.error) {
            pendingEntry.reject(new Error(parsed.error.message ?? "RPC error"));
          } else {
            pendingEntry.resolve(parsed.result);
          }
        }
      } else if (parsed.method) {
        transcript.notifications.push(parsed);
      } else {
        transcript.stdout.push(parsed);
      }
    }
  });

  child.stderr.on("data", (chunk) => {
    transcript.stderr.push(chunk.toString());
  });

  child.on("error", (error) => {
    settleError(error);
  });

  child.on("exit", (code, signal) => {
    if (pending.size > 0) {
      settleError(
        new Error(`codex app-server exited before response: code=${code} signal=${signal}`),
      );
    }
  });

  try {
    await send("initialize", {
      clientInfo: {
        name: "ccpocket_effort_probe",
        version: "1.0.0",
      },
      capabilities: {
        experimentalApi: true,
      },
    });
    child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);

    const threadStart = await send("thread/start", {
      cwd,
      approvalPolicy: "on-request",
      sandbox: "workspace-write",
      effort,
      model: "gpt-5.4",
      experimentalRawEvents: false,
      persistExtendedHistory: true,
    });

    await delay(1500);
    return {
      transcript,
      threadStart,
    };
  } finally {
    child.kill("SIGTERM");
    await delay(300);
  }
}

const results = [];
for (const effort of efforts) {
  results.push(await runProbe(effort));
}

const output = {
  generatedAt: new Date().toISOString(),
  results,
};

writeFileSync(
  new URL("./codex-app-server-effort-probe-output.json", outDir),
  JSON.stringify(output, null, 2),
);

console.log(
  JSON.stringify(
    results.map(({ transcript, threadStart }) => ({
      effort: transcript.effort,
      responseReasoningEffort: threadStart?.reasoningEffort,
      responseCollaborationSettings:
        threadStart?.collaborationMode?.settings?.reasoning_effort,
      threadModel: threadStart?.thread?.model,
    })),
    null,
    2,
  ),
);
