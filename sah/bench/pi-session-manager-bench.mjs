// pi-session-manager-bench.mjs -- the same scaling sweep on pi's real code.
//
//   PI_DIST=<path to pi-coding-agent/dist> node --expose-gc \
//     bench/pi-session-manager-bench.mjs [max-n]
//
// Drives pi's actual SessionManager (in-memory, no file I/O) through node, so the
// numbers are comparable to bench/bench-scale.ss. PI_DIST defaults to the
// installed location on this machine. --expose-gc is needed for live-memory
// figures; timing works without it.

import { randomUUID } from "crypto";

const PI_DIST =
  process.env.PI_DIST ??
  "C:/Users/hgz92/AppData/Local/pi-node/current/node_modules/@earendil-works/pi-coding-agent/dist";
const { SessionManager } = await import(
  PI_DIST.startsWith("file:") ? `${PI_DIST}/core/session-manager.js` : `file:///${PI_DIST}/core/session-manager.js`
);

const measure = (fn) => {
  const t0 = performance.now();
  fn();
  const one = performance.now() - t0;
  if (one > 200) return one;
  const reps = Math.max(1, Math.min(20, Math.floor(200 / one)));
  let best = Infinity;
  for (let i = 0; i < 3; i++) {
    const s = performance.now();
    for (let j = 0; j < reps; j++) fn();
    best = Math.min(best, (performance.now() - s) / reps);
  }
  return best;
};

const fmt = (x) => (x < 0.001 ? "<0.001" : x < 1 ? String(Math.round(x * 1000) / 1000) : String(Math.round(x * 10) / 10));
const padR = (s, n) => String(s).padEnd(n);
const padL = (s, n) => String(s).padStart(n);
const nsPer = (ms, n) => (n ? String(Math.round((ms * 1e6) / n)) : "-");

const buildLog = (n) => {
  const sm = SessionManager.inMemory("/tmp/bench");
  for (let i = 0; i < n; i++) sm.appendMessage({ role: "user", content: "hello there" });
  return sm;
};

const liveBytesPerEntry = (n) => {
  if (!global.gc) return null;
  global.gc();
  const before = process.memoryUsage().heapUsed;
  const sm = buildLog(n);
  if (sm.getEntries().length !== n) throw new Error("bad build");
  global.gc();
  return Math.round((process.memoryUsage().heapUsed - before) / n);
};

const row = (label, ms, n) =>
  console.log("    " + padR(label, 40) + padL(fmt(ms), 12) + padL(nsPer(ms, n), 14));

const sweep = (n) => {
  console.log(`n = ${n}`);
  const tBuild = measure(() => buildLog(n));
  const bpe = liveBytesPerEntry(n);
  console.log(
    "    " + padR("build n entries", 40) + padL(fmt(tBuild), 12) + padL(nsPer(tBuild, n), 14) +
      padL(bpe === null ? "(need --expose-gc)" : `${bpe} B/entry live`, 22),
  );
  const tId = measure(() => {
    for (let i = 0; i < n; i++) randomUUID().slice(0, 8);
  });
  console.log(
    "    " + padR("  of which: n randomUUID().slice(0,8)", 40) + padL(fmt(tId), 12) + padL(nsPer(tId, n), 14),
  );

  const sm = buildLog(n);
  const ids = sm.getEntries().map((e) => e.id);
  row("path walk (getBranch, root -> leaf)", measure(() => sm.getBranch()), n);
  row("getEntry(id) x n", measure(() => { for (const id of ids) sm.getEntry(id); }), n);
  row("getEntries (shallow copy)", measure(() => sm.getEntries()), n);
  row("buildSessionContext()", measure(() => sm.buildSessionContext()), n);
  row("branch(x) x n (fork)", measure(() => { for (const id of ids) sm.branch(id); }), n);
  if (n <= 100000) row("getChildren(parent) x 1000  [O(n) each]", measure(() => { for (let i = 0; i < 1000; i++) sm.getChildren(ids[i]); }), 1000);
  console.log();
};

const max = Number(process.argv[2] ?? 1000000);
console.log("pi SessionManager (in-memory, no I/O) -- scaling sweep");
console.log("totals in ms, third column in ns per element\n");
for (let n = 10000; n <= max; n *= 10) sweep(n);
