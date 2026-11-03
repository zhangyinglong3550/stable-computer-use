/**
 * 假 socket 集成测试：不连真 daemon、不碰 AX，Linux 可跑。
 *
 * 覆盖 PM 补充项 6、7 和阻塞 A 的脚本侧行为：
 * - waitFor / sleep / 写 API 取消后抛 CancelledError，scu js 输出 cancelled JSON、退出码 130；
 * - 只读快照带 runStale 时同样立刻停；
 * - begin_run 的五种失败形态都以退出码 1 结束，脚本不执行。
 *
 *   node --test tests/cancel-socket.test.mjs
 */

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const JSAPI = path.join(ROOT, "cli", "jsapi.mjs");
const JSAPI_URL = pathToFileURL(JSAPI).href;

/** 起一个假 daemon：每个连接读一行 JSON，由 handler 决定回什么。 */
async function fakeDaemon(handler) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scu-fake-"));
  const sock = path.join(dir, "s.sock");
  const seen = [];
  const server = net.createServer((conn) => {
    let buf = "";
    conn.setEncoding("utf8");
    conn.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      const req = JSON.parse(buf.slice(0, nl));
      seen.push(req);
      conn.end(JSON.stringify(handler(req)) + "\n");
    });
    conn.on("error", () => {});
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(sock, resolve);
  });
  return {
    sock,
    seen,
    async close() {
      await new Promise((resolve) => server.close(resolve));
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

/** 用 scu js 跑一段脚本，返回 { code, out, err, ms }。 */
function runJs(body, extraEnv = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scu-script-"));
  const file = path.join(dir, "s.mjs");
  fs.writeFileSync(file, `import { scu } from ${JSON.stringify(JSAPI_URL)};\n${body}\n`);
  return new Promise((resolve) => {
    const t0 = Date.now();
    const child = spawn(process.execPath, [JSAPI, file], {
      env: { ...process.env, SCU_TRACE: "", ...extraEnv },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (code) => {
      fs.rmSync(dir, { recursive: true, force: true });
      resolve({ code, out, err, ms: Date.now() - t0 });
    });
  });
}

function lastJson(out) {
  const line = out.trim().split("\n").filter(Boolean).pop() || "";
  return JSON.parse(line);
}

function beginRunOk(req) {
  return req.cmd === "begin_run" ? { ok: true, runId: 7, completedSteps: 0 } : null;
}

test("waitFor 轮询中途取消：抛 CancelledError，退出码 130，不等到超时", async () => {
  let snapshots = 0;
  const daemon = await fakeDaemon((req) => {
    const start = beginRunOk(req);
    if (start) return start;
    if (req.cmd === "snapshot") {
      snapshots += 1;
      // getApp 1 次 + waitFor 第 1 轮；第 3 次轮询带取消标记。
      if (snapshots >= 3) {
        return { ok: true, app: "Fake", window: "W", elements: [], runCancelled: true };
      }
      return { ok: true, app: "Fake", window: "W", elements: [] };
    }
    return { ok: true };
  });
  try {
    const r = await runJs(`
const app = await scu.getApp("Fake");
await app.waitFor(() => false, { timeoutMs: 6000 });
console.log("AFTER_WAIT");
`, { SCU_SOCK: daemon.sock });
    assert.equal(r.code, 130, r.err);
    assert.ok(!r.out.includes("AFTER_WAIT"), "取消后脚本不应继续执行");
    assert.ok(r.ms < 4000, `应提前结束，实际 ${r.ms}ms`);
    const payload = lastJson(r.out);
    assert.deepEqual(payload, { ok: false, status: "cancelled", completedSteps: 0 });
    assert.ok(snapshots >= 3);
    // 轮询快照带当前 runId，daemon 才能按 run 判定。
    assert.ok(daemon.seen.some((q) => q.cmd === "snapshot" && q.runId === 7));
  } finally {
    await daemon.close();
  }
});

test("只读快照带 runStale：等待立刻停，按 stale_run 退出", async () => {
  let snapshots = 0;
  const daemon = await fakeDaemon((req) => {
    const start = beginRunOk(req);
    if (start) return start;
    if (req.cmd === "snapshot") {
      snapshots += 1;
      if (snapshots >= 2) {
        return { ok: true, app: "Fake", window: "W", elements: [], runStale: true };
      }
      return { ok: true, app: "Fake", window: "W", elements: [] };
    }
    return { ok: true };
  });
  try {
    const r = await runJs(`
const app = await scu.getApp("Fake");
await app.waitFor(() => false, { timeoutMs: 6000 });
console.log("AFTER_WAIT");
`, { SCU_SOCK: daemon.sock });
    assert.equal(r.code, 130, r.err);
    assert.ok(!r.out.includes("AFTER_WAIT"));
    assert.ok(r.ms < 4000);
    assert.deepEqual(lastJson(r.out), {
      ok: false, status: "cancelled", completedSteps: 0, reasonCode: "stale_run",
    });
  } finally {
    await daemon.close();
  }
});

test("scu.sleep 被取消：抛 CancelledError，退出码 130，不睡满", async () => {
  let pings = 0;
  const daemon = await fakeDaemon((req) => {
    const start = beginRunOk(req);
    if (start) return start;
    if (req.cmd === "ping") {
      pings += 1;
      if (pings >= 3) return { ok: true, pid: 1, runCancelled: true };
      return { ok: true, pid: 1 };
    }
    return { ok: true };
  });
  try {
    const r = await runJs(`
await scu.sleep(5000);
console.log("AFTER_SLEEP");
`, { SCU_SOCK: daemon.sock });
    assert.equal(r.code, 130, r.err);
    assert.ok(!r.out.includes("AFTER_SLEEP"), "取消后脚本不应继续执行");
    assert.ok(r.ms < 4000, `应提前结束，实际 ${r.ms}ms`);
    assert.deepEqual(lastJson(r.out), { ok: false, status: "cancelled", completedSteps: 0 });
    assert.ok(pings >= 3);
    assert.ok(daemon.seen.some((q) => q.cmd === "ping" && q.runId === 7));
  } finally {
    await daemon.close();
  }
});

test("过期 runId 的写：按 cancelled 承载 stale_run，退出码 130", async () => {
  const daemon = await fakeDaemon((req) => {
    const start = beginRunOk(req);
    if (start) return start;
    if (req.cmd === "snapshot") return { ok: true, app: "Fake", window: "W", elements: [] };
    if (req.cmd === "click" || req.cmd === "actAndWait") {
      return { ok: false, reasonCode: "stale_run" };
    }
    return { ok: true };
  });
  try {
    const r = await runJs(`
const app = await scu.getApp("Fake");
await app.click("r1");
console.log("AFTER_CLICK");
`, { SCU_SOCK: daemon.sock });
    assert.equal(r.code, 130, r.err);
    assert.ok(!r.out.includes("AFTER_CLICK"), "stale_run 后脚本不应继续执行");
    assert.deepEqual(lastJson(r.out), {
      ok: false, status: "cancelled", completedSteps: 0, reasonCode: "stale_run",
    });
    assert.ok(daemon.seen.some((q) => q.cmd === "click" && q.runId === 7));
  } finally {
    await daemon.close();
  }
});

test("begin_run 失败的五种形态都以退出码 1 结束，脚本不执行", async (t) => {
  const cases = [
    ["socket 不存在", null],
    ["无 runId", { ok: true }],
    ["runId 为 null", { ok: true, runId: null }],
    ["ok:false", { ok: false, reasonCode: "nope" }],
    ["runId 为非数字字符串", { ok: true, runId: "abc" }],
  ];
  for (const [name, resp] of cases) {
    await t.test(name, async () => {
      let sock = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "scu-none-")), "no.sock");
      let daemon = null;
      if (resp) {
        daemon = await fakeDaemon((req) => (req.cmd === "begin_run" ? resp : { ok: true }));
        sock = daemon.sock;
      }
      try {
        const r = await runJs(`console.log("SCRIPT_RAN");`, { SCU_SOCK: sock });
        assert.equal(r.code, 1, `${name}: ${r.err}`);
        assert.ok(!r.out.includes("SCRIPT_RAN"), `${name}: 脚本不应执行`);
        assert.match(r.err, /begin_run 失败/, name);
      } finally {
        if (daemon) await daemon.close();
      }
    });
  }
});

test("act 内的 expect 中途取消：仍返回 status:cancelled，不抛、不记超时", async () => {
  let snapshots = 0;
  const daemon = await fakeDaemon((req) => {
    const start = beginRunOk(req);
    if (start) return start;
    if (req.cmd === "snapshot") {
      snapshots += 1;
      if (snapshots >= 3) {
        return { ok: true, app: "Fake", window: "W", elements: [], runCancelled: true };
      }
      return { ok: true, app: "Fake", window: "W", elements: [] };
    }
    return { ok: true };
  });
  try {
    const r = await runJs(`
const app = await scu.getApp("Fake");
const report = await app.act([{ op: "expect", text: "永远不会出现", timeoutMs: 6000 }], { diff: false });
console.log(JSON.stringify(report));
`, { SCU_SOCK: daemon.sock });
    assert.equal(r.code, 0, r.err);
    assert.ok(r.ms < 4000, `应提前结束，实际 ${r.ms}ms`);
    const report = lastJson(r.out);
    assert.equal(report.status, "cancelled");
    assert.equal(report.ok, false);
    assert.equal(report.cancelled, true);
    assert.equal(report.completedSteps, 0);
    assert.equal(report.steps[0].reasonCode, "cancelled");
  } finally {
    await daemon.close();
  }
});

/** 直接给假 daemon 发一条请求，模拟「另一个进程」。 */
function sendRaw(sock, req) {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(sock);
    let buf = "";
    c.setEncoding("utf8");
    c.on("connect", () => c.write(JSON.stringify(req) + "\n"));
    c.on("data", (d) => {
      buf += d;
      if (buf.includes("\n")) {
        c.destroy();
        resolve(JSON.parse(buf.split("\n")[0]));
      }
    });
    c.on("error", reject);
  });
}

test("A 拿 run 1、B 拿 run 2 后，A 的写请求被 stale_run 拒且不执行", async () => {
  let current = 0;
  const daemon = await fakeDaemon((req) => {
    if (req.cmd === "begin_run") {
      current += 1;
      return { ok: true, runId: current, completedSteps: 0 };
    }
    if (req.cmd === "snapshot") return { ok: true, app: "Fake", window: "W", elements: [] };
    if (["click", "actAndWait", "activate"].includes(req.cmd)) {
      // 判定表：带 runId 但不等于当前主 run 的写请求一律不执行。
      if (req.runId !== current) return { ok: false, reasonCode: "stale_run" };
      return { ok: true, via: "ax" };
    }
    return { ok: true };
  });
  try {
    const a = runJs(`
const app = await scu.getApp("Fake");
await scu.sleep(400);
await app.click("r1");
console.log("AFTER_CLICK");
`, { SCU_SOCK: daemon.sock });
    // 进程 B 在 A 的等待期间 begin_run，把 daemon 的当前 run 换成 2。
    await new Promise((r) => setTimeout(r, 150));
    const b = await sendRaw(daemon.sock, { cmd: "begin_run" });
    assert.equal(b.runId, 2);

    const r = await a;
    assert.equal(r.code, 130, r.err);
    assert.ok(!r.out.includes("AFTER_CLICK"), "stale_run 后脚本不应继续执行");
    assert.deepEqual(lastJson(r.out), {
      ok: false, status: "cancelled", completedSteps: 0, reasonCode: "stale_run",
    });
    // A 的 click 确实带着旧 runId 发出，且被拒绝；没有「执行成功」的 click 记录。
    const clicks = daemon.seen.filter((q) => q.cmd === "click");
    assert.equal(clicks.length, 1);
    assert.equal(clicks[0].runId, 1);
    assert.equal(current, 2);
  } finally {
    await daemon.close();
  }
});
