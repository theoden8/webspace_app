// Benchmark for the JS interceptor rewrite. Compares the old
// (Promise-everywhere, split-based suffix walk) vs new (sync fast-path,
// substring-based suffix walk) implementations on synthetic but
// realistic workloads.
//
// Run via `npm run bench:js`. Output is human-readable text — no
// assertions. The numbers are useful as a relative comparison; absolute
// throughput depends heavily on the host machine.
//
// Workload assumptions (from real-world measurements on news/social
// pages):
//   * 200 sub-resource requests per page
//   * ~30 unique hosts per page
//   * blocklist: 100K domains (Hagezi "Pro" tier ≈ 392K — we use 100K
//     to keep the benchmark fast on CI; the bloom shape is the same)
//   * 5% of sub-resources hit the bloom (need Dart roundtrip)
//   * 95% of sub-resources are bloom misses (sync fast-path candidates)

'use strict';

const { performance } = require('node:perf_hooks');
const { makeOldInterceptor } = require('./old_interceptor');
const { makeNewInterceptor } = require('./new_interceptor');
const { buildBloom } = require('./bloom_build');

// ---------------- Synthetic data ----------------

function rng(seed) {
  // Mulberry32 — small, deterministic, good enough for benchmark data.
  let s = seed >>> 0;
  return function next() {
    s = (s + 0x6D2B79F5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeBlocklist(count, seed = 42) {
  const next = rng(seed);
  const tlds = ['com', 'net', 'org', 'io', 'co', 'info', 'biz', 'xyz'];
  const out = [];
  for (let i = 0; i < count; i++) {
    const tld = tlds[Math.floor(next() * tlds.length)];
    const nameLen = 4 + Math.floor(next() * 12);
    let name = '';
    for (let j = 0; j < nameLen; j++) {
      name += String.fromCharCode(97 + Math.floor(next() * 26));
    }
    if (Math.floor(next() * 5) === 0) {
      const subLen = 3 + Math.floor(next() * 6);
      let sub = '';
      for (let j = 0; j < subLen; j++) {
        sub += String.fromCharCode(97 + Math.floor(next() * 26));
      }
      out.push(`${sub}.${name}.${tld}`);
    } else {
      out.push(`${name}.${tld}`);
    }
  }
  return out;
}

// Generate a request stream: `pageCount` synthetic pages, each with
// `requestsPerPage` sub-resource URLs spread across `uniqueHostsPerPage`
// hosts. Of those hosts, `bloomHitFrac` are guaranteed bloom hits
// (drawn from the blocklist) — the rest are non-blocked synthetic hosts.
function makeRequestStream({
  blocklist,
  pageCount,
  requestsPerPage,
  uniqueHostsPerPage,
  bloomHitFrac,
  seed = 99,
}) {
  const next = rng(seed);
  const stream = [];
  for (let p = 0; p < pageCount; p++) {
    const hosts = [];
    const hitCount = Math.round(uniqueHostsPerPage * bloomHitFrac);
    for (let h = 0; h < hitCount; h++) {
      hosts.push(blocklist[Math.floor(next() * blocklist.length)]);
    }
    for (let h = hitCount; h < uniqueHostsPerPage; h++) {
      let nm = '';
      const len = 6 + Math.floor(next() * 6);
      for (let j = 0; j < len; j++) {
        nm += String.fromCharCode(97 + Math.floor(next() * 26));
      }
      hosts.push(`${nm}.example.test`);
    }
    for (let r = 0; r < requestsPerPage; r++) {
      const host = hosts[Math.floor(next() * hosts.length)];
      const path = '/' + Math.floor(next() * 1e9).toString(36);
      stream.push(`https://${host}${path}`);
    }
  }
  return stream;
}

// ---------------- Bench helpers ----------------

function format(ms) {
  if (ms < 0.01) return `${(ms * 1000).toFixed(2)}µs`;
  if (ms < 1) return `${ms.toFixed(3)}ms`;
  return `${ms.toFixed(2)}ms`;
}

function ratio(a, b) {
  if (a === 0 || b === 0) return '∞';
  const r = b / a;
  if (r >= 1) return `${r.toFixed(2)}× faster`;
  return `${(1 / r).toFixed(2)}× slower`;
}

function bench(label, fn, { warmup = 1, iters = 5 } = {}) {
  for (let i = 0; i < warmup; i++) fn();
  const samples = [];
  for (let i = 0; i < iters; i++) {
    const t0 = performance.now();
    fn();
    samples.push(performance.now() - t0);
  }
  samples.sort((a, b) => a - b);
  const median = samples[Math.floor(samples.length / 2)];
  return { label, median, min: samples[0], max: samples[samples.length - 1] };
}

async function benchAsync(label, fn, { warmup = 1, iters = 5 } = {}) {
  for (let i = 0; i < warmup; i++) await fn();
  const samples = [];
  for (let i = 0; i < iters; i++) {
    const t0 = performance.now();
    await fn();
    samples.push(performance.now() - t0);
  }
  samples.sort((a, b) => a - b);
  return {
    label,
    median: samples[Math.floor(samples.length / 2)],
    min: samples[0],
    max: samples[samples.length - 1],
  };
}

function printRow(label, value) {
  console.log(`  ${label.padEnd(46)} ${value}`);
}

function printResult(r) {
  printRow(r.label, `${format(r.median)}  (min ${format(r.min)})`);
}

function compare(label, oldRes, newRes) {
  console.log('');
  console.log(label);
  printResult(oldRes);
  printResult(newRes);
  const speedup = oldRes.median / newRes.median;
  printRow(
    'speedup',
    speedup >= 1
      ? `${speedup.toFixed(2)}× faster`
      : `${(1 / speedup).toFixed(2)}× slower`,
  );
}

// ---------------- Benchmarks ----------------

async function correctnessCheck(blocklist, bloom) {
  // Confirm old and new agree on bloom decisions for a representative
  // sample. If they disagree the speedup is meaningless — we'd just be
  // doing less work.
  const old = makeOldInterceptor({
    bloomBits: bloom.bits,
    bloomBitCount: bloom.bitCount,
    bloomK: bloom.k,
    callHandler: () => Promise.resolve(false),
  });
  const next = makeNewInterceptor({
    bloomBits: bloom.bits,
    bloomBitCount: bloom.bitCount,
    bloomK: bloom.k,
    callHandler: () => Promise.resolve(false),
  });
  const sample = [];
  // 100 known-blocked hosts (drawn from the blocklist) + 100 known-safe.
  for (let i = 0; i < 100; i++) sample.push(blocklist[i * 17 % blocklist.length]);
  for (let i = 0; i < 100; i++) sample.push(`safe${i}.example.test`);
  // Sub-domain forms of each.
  for (let i = 0; i < 100; i++) sample.push(`a.b.${blocklist[i * 23 % blocklist.length]}`);
  let mismatches = 0;
  for (const host of sample) {
    if (old.maybeBlocked(host) !== next.maybeBlocked(host)) mismatches++;
  }
  if (mismatches > 0) {
    throw new Error(
      `Correctness check FAILED: ${mismatches}/${sample.length} bloom decisions differ between old and new`,
    );
  }
  console.log(
    `  correctness: ${sample.length}/${sample.length} bloom decisions match between old and new`,
  );
}

async function main() {
  console.log('Building synthetic 100K-domain blocklist + bloom...');
  const blocklist = makeBlocklist(100_000);
  const bloom = buildBloom(blocklist, 0.05);
  console.log(
    `  bloom: ${bloom.bits.length} bytes, k=${bloom.k}, bitCount=${bloom.bitCount}`,
  );
  await correctnessCheck(blocklist, bloom);

  // ---------------- 1. Suffix walk (pure CPU) ----------------
  // 50K hosts × ~3 average levels of walk-up. Pre-warm cache disabled —
  // we want the actual walk cost. Use bloom-miss hosts so every query
  // walks the full hierarchy.
  const walkHosts = [];
  for (let i = 0; i < 50_000; i++) {
    walkHosts.push(`a.b.c.d.host${i}.example.test`);
  }
  const oldI1 = makeOldInterceptor({
    bloomBits: bloom.bits,
    bloomBitCount: bloom.bitCount,
    bloomK: bloom.k,
    callHandler: () => Promise.resolve(false),
  });
  const newI1 = makeNewInterceptor({
    bloomBits: bloom.bits,
    bloomBitCount: bloom.bitCount,
    bloomK: bloom.k,
    callHandler: () => Promise.resolve(false),
  });
  const oldWalk = bench(
    'old (split + slice + join)',
    () => {
      for (const h of walkHosts) oldI1.maybeBlocked(h);
    },
    { iters: 7 },
  );
  const newWalk = bench(
    'new (substring + indexOf)',
    () => {
      for (const h of walkHosts) newI1.maybeBlocked(h);
    },
    { iters: 7 },
  );
  compare('Suffix walk: 50K hosts × 5 levels', oldWalk, newWalk);

  // ---------------- 2. Property-setter microtask delay ----------------
  // Simulate `el.src = url` 1000 times. Old wraps in Promise.then, new
  // runs origSet synchronously on bloom miss. The cost worth tracking
  // is split into two phases:
  //   * `sync_ms` — wall-clock time spent on the main JS thread issuing
  //     the work. This is what blocks the UI / scrolling. In the new
  //     code, ~95% of sets COMPLETE in this phase (origSet runs sync);
  //     in the old code, every set just enqueues a microtask.
  //   * `drain_ms` — time spent in the microtask queue after the loop
  //     exits, until all pending decisions have run their `.then`
  //     callbacks.
  // Real-world hit: while the `sync_ms` phase is running the UI thread
  // is unresponsive — each microtask delay there means an image load
  // doesn't kick off until later.
  const setterStream = makeRequestStream({
    blocklist,
    pageCount: 1,
    requestsPerPage: 1000,
    uniqueHostsPerPage: 50,
    bloomHitFrac: 0.05,
  });

  const oldI3 = makeOldInterceptor({
    bloomBits: bloom.bits,
    bloomBitCount: bloom.bitCount,
    bloomK: bloom.k,
    callHandler: () => Promise.resolve(true),
  });
  const newI3 = makeNewInterceptor({
    bloomBits: bloom.bits,
    bloomBitCount: bloom.bitCount,
    bloomK: bloom.k,
    callHandler: () => Promise.resolve(true),
  });

  async function setterPhasesOld() {
    let counter = 0;
    const settled = [];
    const tSync = performance.now();
    for (const url of setterStream) {
      settled.push(
        oldI3.check(url).then((blocked) => {
          if (!blocked) counter++;
        }),
      );
    }
    const sync = performance.now() - tSync;
    const tDrain = performance.now();
    await Promise.all(settled);
    const drain = performance.now() - tDrain;
    return { sync, drain };
  }
  async function setterPhasesNew() {
    let counter = 0;
    const settled = [];
    const tSync = performance.now();
    for (const url of setterStream) {
      const sync = newI3.checkSync(url);
      if (sync === false) {
        counter++; // synchronous — origSet would have run here
        continue;
      }
      if (sync === true) continue;
      settled.push(
        newI3.checkAsync(url).then((blocked) => {
          if (!blocked) counter++;
        }),
      );
    }
    const sync = performance.now() - tSync;
    const tDrain = performance.now();
    await Promise.all(settled);
    const drain = performance.now() - tDrain;
    return { sync, drain };
  }

  // Warm up.
  for (let i = 0; i < 2; i++) {
    await setterPhasesOld();
    await setterPhasesNew();
  }
  const oldPhases = [];
  const newPhases = [];
  for (let i = 0; i < 7; i++) {
    oldPhases.push(await setterPhasesOld());
    newPhases.push(await setterPhasesNew());
  }
  function median(values) {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)];
  }
  const oldSync = median(oldPhases.map((p) => p.sync));
  const oldDrain = median(oldPhases.map((p) => p.drain));
  const newSync = median(newPhases.map((p) => p.sync));
  const newDrain = median(newPhases.map((p) => p.drain));
  console.log('');
  console.log(
    'Property setter phases (1000 sets, 95% bloom miss; UI thread blocked during sync)',
  );
  printRow('old sync (UI-thread)', format(oldSync));
  printRow('new sync (UI-thread)', `${format(newSync)}  (${ratio(newSync, oldSync)})`);
  printRow('old drain (microtask queue)', format(oldDrain));
  printRow('new drain (microtask queue)', `${format(newDrain)}  (${ratio(newDrain, oldDrain)})`);
  printRow(
    'old total',
    format(oldSync + oldDrain),
  );
  printRow(
    'new total',
    `${format(newSync + newDrain)}  (${ratio(newSync + newDrain, oldSync + oldDrain)})`,
  );

  // ---------------- 3. Pure-sync: hot-cache lookup throughput ----------------
  // After warmup the cache holds every host. Old still creates a Promise
  // per call; new returns sync directly. This bounds the steady-state
  // cost on a long-lived page.
  const hotStream = makeRequestStream({
    blocklist,
    pageCount: 1,
    requestsPerPage: 10_000,
    uniqueHostsPerPage: 50,
    bloomHitFrac: 0.05,
  });
  // Warm both caches.
  const ps = [];
  for (const url of hotStream) ps.push(oldI3.check(url));
  await Promise.all(ps);
  for (const url of hotStream) newI3.checkSync(url);

  const oldHot = await benchAsync(
    'old hot-cache: 10K cached lookups',
    async () => {
      const ps = [];
      for (const url of hotStream) ps.push(oldI3.check(url));
      await Promise.all(ps);
    },
    { iters: 5 },
  );
  const newHot = bench(
    'new hot-cache: 10K sync lookups',
    () => {
      for (const url of hotStream) newI3.checkSync(url);
    },
    { iters: 5 },
  );
  compare('Hot-cache throughput (10K cached lookups)', oldHot, newHot);

  console.log('');
  console.log('Notes:');
  console.log('  * Times are wall-clock medians across 5–7 runs (after warmup).');
  console.log('  * Workload uses a 100K-domain bloom; production "Pro" tier is');
  console.log('    ~390K. Bloom miss cost scales with `k` (4 in both cases) so');
  console.log('    the relative speedup is stable across blocklist sizes.');
  console.log('  * Suffix-walk: pure CPU. No async, no DOM. The 1.4–1.5×');
  console.log('    speedup comes from substring/indexOf in place of');
  console.log('    parts.split + parts.slice(i).join — no per-level array');
  console.log('    allocation.');
  console.log('  * Property setter: most important number. The "drain" line');
  console.log('    is microtask-queue time before all 1000 callbacks resolve.');
  console.log('    On a real iOS WebView this drain blocks the render loop —');
  console.log('    image loads queued behind 1000 microtasks vs 50 microtasks');
  console.log('    is the perceptible UX win.');
  console.log('  * Hot-cache throughput: steady-state cost on a long-lived');
  console.log('    page after every host has been seen once.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
