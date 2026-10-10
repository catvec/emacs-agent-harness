#!/usr/bin/env node
// A real, headless Agent Client Protocol (ACP) client used by
// test/harness-acp-client-test.el.  It is built on the official
// third-party TypeScript SDK, `@agentclientprotocol/sdk` (the client
// library Zed-class clients use), and speaks the real wire protocol
// (JSON-RPC 2.0, one message per line) over stdio to
// scripts/harness-acp-stdio, the harness's stdio bridge.
//
// It records every raw JSON line it sends and receives so the ERT
// suite can assert on both the SDK's validated view and the exact
// frames.  On success it prints exactly one line
//
//   HARNESS-ACP-CLIENT-REPORT { ...json... }
//
// and exits 0; on failure it prints the same marker with
// { ok: false, error, raw } and exits 1.  `--probe` only resolves the
// SDK and exits 0 when one is available, 3 when it is not (the suite
// skips the test on 3).
//
// CI: pin the SDK with
//   npm install --no-save @agentclientprotocol/sdk@0.21.0
// in the repository root, or set HARNESS_ACP_SDK to a node_modules
// directory (or the package directory itself).

import { spawn } from "node:child_process";
import { Writable, Readable } from "node:stream";
import { readFileSync, existsSync, readdirSync, writeSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..");
const REPORT = "HARNESS-ACP-CLIENT-REPORT";
const MAX_RAW = 500;

function hasFlag(argv, name) {
  return argv.includes(`--${name}`);
}

function flagValue(argv, name, fallback) {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && argv[i + 1] !== undefined) return argv[i + 1];
  return fallback;
}

function sdkCandidates() {
  const out = [];
  const push = (p) => {
    if (p && !out.includes(p)) out.push(resolve(p));
  };
  push(process.env.HARNESS_ACP_SDK);
  push(join(REPO, "node_modules"));
  try {
    push(execFileSync("npm", ["root", "-g"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim());
  } catch {
    /* npm unavailable: fall through to the fixed paths */
  }
  push("/usr/lib/node_modules");
  push("/usr/local/lib/node_modules");
  // SDK copies bundled with installed CLIs (Gemini CLI, pi...).
  try {
    for (const d of readdirSync("/usr/lib/node_modules")) {
      const full = join("/usr/lib/node_modules", d);
      if (d.startsWith("@")) {
        for (const p of readdirSync(full)) push(join(full, p, "node_modules"));
      } else {
        push(join(full, "node_modules"));
      }
    }
  } catch {
    /* ignore */
  }
  return out;
}

function sdkInfoAt(dir) {
  const nested = join(dir, "@agentclientprotocol", "sdk", "package.json");
  if (existsSync(nested)) {
    return { pkgDir: join(dir, "@agentclientprotocol", "sdk"), version: JSON.parse(readFileSync(nested, "utf8")).version };
  }
  const pkg = join(dir, "package.json");
  if (existsSync(pkg)) {
    const meta = JSON.parse(readFileSync(pkg, "utf8"));
    if (meta.name === "@agentclientprotocol/sdk") return { pkgDir: dir, version: meta.version };
  }
  return null;
}

function cmpVersion(a, b) {
  const na = a.split(".").map((n) => Number(n) || 0);
  const nb = b.split(".").map((n) => Number(n) || 0);
  for (let i = 0; i < Math.max(na.length, nb.length); i++) {
    const d = (na[i] || 0) - (nb[i] || 0);
    if (d !== 0) return d;
  }
  return 0;
}

function resolveSdk() {
  let best = null;
  for (const dir of sdkCandidates()) {
    const info = sdkInfoAt(dir);
    if (info && (!best || cmpVersion(info.version, best.version) > 0)) best = info;
  }
  return best;
}

// Module-scope state of the single connection a process drives.
let inLines = [];
let outLines = [];
let inMsgs = [];
let updates = [];
let phase = 0;
let inBuf = "";
let outBuf = "";
const inDec = new TextDecoder();
const outDec = new TextDecoder();

function pushLine(list, line) {
  line = line.trim();
  if (!line) return;
  list.push(line);
  if (list.length > MAX_RAW) list.shift();
}

function recordIncoming(line) {
  pushLine(inLines, line);
  let msg = null;
  try {
    msg = JSON.parse(line);
  } catch {
    /* a line is only recorded as raw when it is not JSON */
  }
  if (msg) {
    inMsgs.push(msg);
    if (msg.method === "session/update" && msg.params && msg.params.update) {
      const u = msg.params.update;
      updates.push({
        kind: u.sessionUpdate,
        nodeId: u._harness && u._harness.nodeId,
        text: u.content && u.content.text,
        raw: line,
        phase,
      });
    }
  }
}

function recordOutgoing(chunk) {
  outBuf += outDec.decode(chunk, { stream: true });
  let nl;
  while ((nl = outBuf.indexOf("\n")) >= 0) {
    pushLine(outLines, outBuf.slice(0, nl));
    outBuf = outBuf.slice(nl + 1);
  }
}

function markPhase() {
  return ++phase;
}

function cleanUpdate(u) {
  return { kind: u.kind, nodeId: u.nodeId, text: u.text, raw: u.raw };
}

async function runScenario(sdk, scenario, opts) {
  const child = spawn(process.execPath, [opts.agent], { stdio: ["pipe", "pipe", "inherit"] });

  const inTap = new TransformStream({
    transform(chunk, ctrl) {
      inBuf += inDec.decode(chunk, { stream: true });
      let nl;
      while ((nl = inBuf.indexOf("\n")) >= 0) {
        recordIncoming(inBuf.slice(0, nl));
        inBuf = inBuf.slice(nl + 1);
      }
      ctrl.enqueue(chunk);
    },
  });

  const outTap = new TransformStream({
    transform(chunk, ctrl) {
      recordOutgoing(chunk);
      ctrl.enqueue(chunk);
    },
  });

  outTap.readable.pipeTo(Writable.toWeb(child.stdin)).catch(() => {});
  const input = Readable.toWeb(child.stdout).pipeThrough(inTap);
  const stream = sdk.ndJsonStream(outTap.writable, input);

  const client = {
    sessionUpdate: async () => {},
    requestPermission: async () => ({ outcome: { outcome: "selected", optionId: "allow-once" } }),
    readTextFile: async () => ({ content: "" }),
    writeTextFile: async () => ({}),
    // The harness sends its own `_harness/event' notifications; accept
    // and ignore them rather than fail the JSON-RPC dispatch.
    extNotification: async () => {},
  };

  const conn = new sdk.ClientSideConnection(() => client, stream);

  try {
    if (scenario === "smoke") return await smoke(sdk, conn, opts);
    if (scenario === "virtual") return await virtual(sdk, conn, opts);
    if (scenario === "task") return await task(sdk, conn, opts);
    throw new Error(`unknown scenario ${scenario}`);
  } finally {
    child.kill();
  }
}

async function initialize(sdk, conn) {
  return conn.initialize({ protocolVersion: sdk.PROTOCOL_VERSION, clientCapabilities: {} });
}

function initRawResponse() {
  return inMsgs.find((m) => m.result && typeof m.result === "object" && "protocolVersion" in m.result && m.result.agentInfo);
}

async function smoke(sdk, conn, opts) {
  const init = await initialize(sdk, conn);
  const initRaw = initRawResponse();
  const methods = initRaw && initRaw.result && initRaw.result._harness ? initRaw.result._harness.methods : [];
  const session = await conn.newSession({
    cwd: opts.projectA,
    mcpServers: [],
    _harness: { model: "demo:scripted" },
  });
  const promptPhase = markPhase();
  const prompt = await conn.prompt({ sessionId: session.sessionId, prompt: [{ type: "text", text: "give me the tour" }] });
  const kinds = [...new Set(updates.filter((u) => u.phase >= promptPhase).map((u) => u.kind))];
  return {
    init: {
      protocolVersion: init.protocolVersion,
      agentInfoName: init.agentInfo && init.agentInfo.name,
      loadSession: !!(init.agentCapabilities && init.agentCapabilities.loadSession),
      methods,
    },
    sessionId: session.sessionId,
    stopReason: prompt.stopReason,
    kinds,
  };
}

async function listSessions(conn, cwd) {
  if (typeof conn.listSessions === "function") return conn.listSessions({ cwd });
  return conn.extMethod("session/list", { cwd });
}

async function virtual(sdk, conn, opts) {
  await initialize(sdk, conn);
  await conn.newSession({ cwd: opts.projectA, mcpServers: [], _harness: { model: "demo:scripted" } });
  const listResp = await listSessions(conn, opts.projectA);
  const listed = (listResp.sessions || []).map((s) => ({ sessionId: s.sessionId, title: s.title, cwd: s.cwd }));

  const loadPhase = markPhase();
  await conn.loadSession({ sessionId: "harness:projects", cwd: opts.projectA, mcpServers: [] });
  const loadUpdates = updates.filter((u) => u.phase >= loadPhase);

  await conn.newSession({ cwd: opts.projectB, mcpServers: [], _harness: { model: "demo:scripted" } });
  const refreshPhase = markPhase();
  const prompt = await conn.prompt({
    sessionId: "harness:projects",
    prompt: [{ type: "text", text: "refresh" }],
  });
  const refreshUpdates = updates.filter((u) => u.phase >= refreshPhase);

  return {
    listed,
    loadUpdates: loadUpdates.map(cleanUpdate),
    refreshUpdates: refreshUpdates.map(cleanUpdate),
    refreshStopReason: prompt.stopReason,
  };
}

async function task(sdk, conn, opts) {
  const text = opts.taskText || "Add a --verbose flag to the CLI";
  await initialize(sdk, conn);
  markPhase();
  await conn.loadSession({ sessionId: "harness:new-task", cwd: opts.projectA, mcpServers: [] });
  const promptPhase = markPhase();
  const prompt = await conn.prompt({ sessionId: "harness:new-task", prompt: [{ type: "text", text }] });
  const promptUpdates = updates.filter((u) => u.phase >= promptPhase);
  const taskList = await conn.extMethod("_harness/task/list", { cwd: opts.projectA });
  const tasks = (Array.isArray(taskList) ? taskList : []).map((t) => ({
    id: t.id,
    prompt: t.prompt,
    cwd: t.cwd,
    state: t.state,
  }));
  const confirm = promptUpdates.find((u) => u.kind === "agent_message_chunk");
  return { stopReason: prompt.stopReason, tasks, confirmText: confirm && confirm.text, prompt: text };
}

async function main() {
  const argv = process.argv.slice(2);
  const probe = hasFlag(argv, "probe");
  const sdk = resolveSdk();

  if (probe) {
    if (!sdk) {
      process.stderr.write("harness-acp-client: no @agentclientprotocol/sdk found\n");
      process.exit(3);
    }
    process.exit(0);
  }

  const scenario = flagValue(argv, "scenario", "smoke");
  const agent = flagValue(argv, "agent", join(REPO, "scripts", "harness-acp-stdio"));
  const timeoutMs = Number(flagValue(argv, "timeout", "120")) * 1000;

  const report = {
    ok: false,
    scenario,
    sdk: sdk ? { version: sdk.version, path: join(sdk.pkgDir, "dist", "acp.js") } : null,
    raw: { in: [], out: [] },
  };

  let finished = false;
  function finish(code) {
    if (finished) return;
    finished = true;
    report.raw.in = inLines;
    report.raw.out = outLines;
    // Write synchronously so the report cannot be lost when we exit.
    const buf = Buffer.from(`${REPORT} ${JSON.stringify(report)}\n`, "utf8");
    let off = 0;
    while (off < buf.length) {
      try {
        off += writeSync(1, buf, off, buf.length - off);
      } catch {
        break;
      }
    }
    process.exit(code);
  }

  const killer = setTimeout(() => {
    report.error = `client timed out after ${timeoutMs / 1000}s`;
    finish(1);
  }, timeoutMs);

  if (!sdk) {
    report.error = "no @agentclientprotocol/sdk found";
    finish(3);
    return;
  }

  let acp;
  try {
    acp = await import(pathToFileURL(join(sdk.pkgDir, "dist", "acp.js")).href);
  } catch (err) {
    report.error = `cannot load @agentclientprotocol/sdk: ${err && err.stack ? err.stack : err}`;
    finish(1);
    return;
  }

  try {
    const frag = await runScenario(acp, scenario, {
      agent,
      projectA: flagValue(argv, "project-a", process.cwd()),
      projectB: flagValue(argv, "project-b", process.cwd()),
      taskText: flagValue(argv, "task-text", null),
    });
    Object.assign(report, frag);
    report.ok = true;
    finish(0);
  } catch (err) {
    report.error = err && err.stack ? err.stack : String(err);
    finish(1);
  }
}

main();
