// Real-list JS interceptor bench — EasyList + Hagezi Ultimate.
//
// Companion to blocking.bench.js, which uses synthetic data. This one
// loads the actual production lists so we can see:
//   * bloom build time + size at production scale
//   * bloom false-positive rate against a non-block host stream
//   * suffix-walk cost on real domain shapes (deep + shallow mixed)
//   * sync fast-path throughput, separated by block vs non-block
//   * roundtrip rate (= fraction of requests that escape the JS sync
//     path and need a Dart callHandler)
//
// Lists are NOT bundled. Cache them once under tmp/ and re-use:
//
//   mkdir -p tmp/blocklists
//   curl -fL -o tmp/blocklists/easylist.txt \
//     https://easylist.to/easylist/easylist.txt
//   curl -fL -o tmp/blocklists/easyprivacy.txt \
//     https://easylist.to/easylist/easyprivacy.txt
//   curl -fL -o tmp/blocklists/hagezi_ultimate.txt \
//     https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/domains/ultimate.txt
//
//   node test/js/perf/blocking_real.bench.js
//
// Override the cache directory with BLOCKLIST_DIR=/some/path.
//
// The per-list parsers mirror what the production DNS pipeline pulls
// out of each list:
//   * Hagezi: bare domain per line, `#` comment lines.
//   * EasyList: only `||domain^` (and `||domain`) rules contribute
//     standalone DNS-style domains. ##cosmetic / #?# text-hide /
//     regex / option-laden network rules belong to the adblock-rust
//     engine and aren't sampled here.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { makeNewInterceptor } = require('./new_interceptor');
const { buildBloom } = require('./bloom_build');

const CACHE_DIR = process.env.BLOCKLIST_DIR ||
  path.resolve(__dirname, '../../../tmp/blocklists');

// ---------------- List loading ----------------

function loadHagezi(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const out = new Set();
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t || t.charCodeAt(0) === 35 /* # */) continue;
    out.add(t.toLowerCase());
  }
  return out;
}

// Pull plain `||domain^` (and `||domain`) rules out of EasyList; the
// option-laden / cosmetic / regex shapes are out of scope for this
// host-only benchmark.
const ABP_DOMAIN_RE = /^\|\|([a-zA-Z0-9._-]+)\^?$/;

function loadEasyListDomains(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const out = new Set();
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t || t.charCodeAt(0) === 33 /* ! */ || t.charCodeAt(0) === 91 /* [ */) continue;
    // Strip trailing options before matching (||tracker.com^$third-party).
    let pattern = t;
    const dollar = t.lastIndexOf('$');
    if (dollar > 0) {
      const after = t.substring(dollar + 1);
      if (!after.includes('//') && !after.startsWith('/')) {
        pattern = t.substring(0, dollar);
      }
    }
    const m = ABP_DOMAIN_RE.exec(pattern);
    if (m) out.add(m[1].toLowerCase());
  }
  return out;
}

// ---------------- Workloads ----------------

function rng(seed) {
  let s = seed >>> 0;
  return function next() {
    s = (s + 0x6D2B79F5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// "Real-shape" non-block hosts: shallow .com/.org/.net and a sprinkling
// of CDN-shaped 4-label hosts. Deliberately constructed so suffix walk
// has to visit multiple parents on most queries — that's the realistic
// cost on a long-tail page.
function makeNonBlockHosts(count, seed = 11) {
  const next = rng(seed);
  const tlds = ['com', 'net', 'org', 'io', 'co'];
  const out = [];
  for (let i = 0; i < count; i++) {
    const tld = tlds[(next() * tlds.length) | 0];
    const labelLen = 6 + ((next() * 8) | 0);
    let name = '';
    for (let j = 0; j < labelLen; j++) {
      name += String.fromCharCode(97 + ((next() * 26) | 0));
    }
    if ((next() * 4) | 0) {
      // Mostly add a CDN-style sub: cdn1.shop.example.com
      const sub = ['cdn1', 'cdn2', 'static', 'img', 'i', 'edge', 'assets'][
        (next() * 7) | 0
      ];
      out.push(`${sub}.${name}.${tld}`);
    } else {
      out.push(`${name}.${tld}`);
    }
  }
  return out;
}

function sampleArray(arr, count, seed = 22) {
  const next = rng(seed);
  const out = new Array(count);
  for (let i = 0; i < count; i++) {
    out[i] = arr[(next() * arr.length) | 0];
  }
  return out;
}

// ---------------- Helpers ----------------

function fmt(ms) {
  if (ms < 0.01) return `${(ms * 1000).toFixed(2)}us`;
  if (ms < 1) return `${ms.toFixed(3)}ms`;
  return `${ms.toFixed(2)}ms`;
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[(sorted.length / 2) | 0];
}

function bench(label, fn, { warmup = 1, iters = 5 } = {}) {
  for (let i = 0; i < warmup; i++) fn();
  const samples = [];
  for (let i = 0; i < iters; i++) {
    const t0 = performance.now();
    fn();
    samples.push(performance.now() - t0);
  }
  const sorted = [...samples].sort((a, b) => a - b);
  return {
    label,
    median: sorted[(sorted.length / 2) | 0],
    min: sorted[0],
    max: sorted[sorted.length - 1],
  };
}

function row(label, value) {
  console.log(`  ${label.padEnd(50)} ${value}`);
}

function reportBench(r) {
  row(r.label, `${fmt(r.median)} (min ${fmt(r.min)} max ${fmt(r.max)})`);
}

// ---------------- Bench ----------------

function ensureFile(name) {
  const file = path.join(CACHE_DIR, name);
  if (!fs.existsSync(file)) {
    console.error(
      `Missing ${file}.\n` +
      `Cache the lists first (see header of ${path.basename(__filename)}).`,
    );
    process.exit(2);
  }
  return file;
}

function main() {
  const easylistFile = ensureFile('easylist.txt');
  const easyprivacyFile = ensureFile('easyprivacy.txt');
  const hageziFile = ensureFile('hagezi_ultimate.txt');

  console.log('Loading lists...');
  const t0 = performance.now();
  const dns = loadHagezi(hageziFile);
  const tDns = performance.now() - t0;

  const t1 = performance.now();
  const abp = new Set([
    ...loadEasyListDomains(easylistFile),
    ...loadEasyListDomains(easyprivacyFile),
  ]);
  const tAbp = performance.now() - t1;

  const merged = new Set([...dns, ...abp]);
  console.log(`  DNS  domains: ${dns.size.toLocaleString()} (parsed in ${fmt(tDns)})`);
  console.log(`  ABP  domains: ${abp.size.toLocaleString()} (parsed in ${fmt(tAbp)})`);
  console.log(`  merged       : ${merged.size.toLocaleString()}`);
  console.log(`  ABP novel    : ${[...abp].filter((d) => !dns.has(d)).length.toLocaleString()} (not also in DNS)`);

  console.log('\nBuilding bloom (fpRate=0.05)...');
  const t2 = performance.now();
  const items = [...merged];
  const bloom = buildBloom(items, 0.05);
  const tBuild = performance.now() - t2;
  console.log(
    `  bits=${bloom.bits.length} bytes (${(bloom.bits.length / 1024 / 1024).toFixed(2)} MiB)` +
    `, k=${bloom.k}, bitCount=${bloom.bitCount.toLocaleString()}, build=${fmt(tBuild)}`,
  );

  // Two host pools.
  const nonBlockHosts = makeNonBlockHosts(50_000);
  const blockHostsAll = [...dns];

  // ---------- Bloom membership accuracy ----------
  // Hosts that ARE in the set: every one must be a bloom hit
  // (no false negatives possible). Hosts NOT in the set: the bloom
  // tells us whether it would short-circuit (no Dart roundtrip) or
  // would have to escalate (false positive).
  console.log('\nBloom membership on real lists:');
  const interceptor = makeNewInterceptor({
    bloomBits: bloom.bits,
    bloomBitCount: bloom.bitCount,
    bloomK: bloom.k,
    callHandler: () => Promise.resolve(false),
  });

  // Sample of in-set hosts.
  const inSetSample = sampleArray(blockHostsAll, 20_000, 33);
  let inSetHits = 0;
  for (const h of inSetSample) {
    if (interceptor.bloomContains(h)) inSetHits++;
  }
  row('in-set hosts (n=20000): bloom hits',
      `${inSetHits} (${(100 * inSetHits / inSetSample.length).toFixed(2)}% — must be 100%)`);

  // Synthetic non-block hosts.
  let outSetFp = 0;
  for (const h of nonBlockHosts) {
    if (interceptor.bloomContains(h)) outSetFp++;
  }
  row('non-block hosts (n=50000): bloom false positives',
      `${outSetFp} (${(100 * outSetFp / nonBlockHosts.length).toFixed(3)}% — target ≤ 5%)`);

  // ---------- Suffix-walk cost ----------
  // Block path: maybeBlocked returns true on the first label (bloom
  // hit happens immediately on the leaf host). Cost is one bloom probe.
  // Non-block path: walks every label up to the public suffix without
  // ever hitting. Each level pays one bloom probe = k FNV-1a hashes.
  console.log('\nSuffix walk (cold cache, no Dart roundtrip):');
  const blockHosts = sampleArray(blockHostsAll, 50_000, 44);

  const blockWalk = bench(
    'block path: 50K real blocked hosts',
    () => {
      for (const h of blockHosts) interceptor.maybeBlocked(h);
    },
    { iters: 7 },
  );
  reportBench(blockWalk);
  row('  per-call (block)',
      `${(blockWalk.median * 1000 / blockHosts.length).toFixed(3)}us`);

  const nonBlockWalk = bench(
    'non-block path: 50K synthetic safe hosts',
    () => {
      for (const h of nonBlockHosts) interceptor.maybeBlocked(h);
    },
    { iters: 7 },
  );
  reportBench(nonBlockWalk);
  row('  per-call (non-block)',
      `${(nonBlockWalk.median * 1000 / nonBlockHosts.length).toFixed(3)}us`);

  // ---------- Full checkSync flow (URL parse + cache + bloom) ----------
  // Mirrors what runs on every fetch / XHR / src= setter.
  console.log('\nFull checkSync (URL parse + FIFO cache + bloom + walk):');

  const blockUrls = blockHosts.map((h) => `https://${h}/path`);
  const nonBlockUrls = nonBlockHosts.map((h) => `https://${h}/path`);

  // Cold cache each iteration: rebuild interceptor.
  function freshInterceptor() {
    return makeNewInterceptor({
      bloomBits: bloom.bits,
      bloomBitCount: bloom.bitCount,
      bloomK: bloom.k,
      callHandler: () => Promise.resolve(false),
    });
  }

  // Cold-cache: every URL is fresh.
  // (For block URLs the result is `undefined` -> Dart roundtrip needed.)
  const coldBlock = bench(
    'cold cache, block URLs (50K) -> undecided (roundtrip)',
    () => {
      const i = freshInterceptor();
      let undecided = 0;
      for (const u of blockUrls) {
        if (i.checkSync(u) === undefined) undecided++;
      }
      if (undecided !== blockUrls.length) {
        throw new Error(`expected all undecided, got ${undecided}/${blockUrls.length}`);
      }
    },
    { iters: 5 },
  );
  reportBench(coldBlock);
  row('  per-call', `${(coldBlock.median * 1000 / blockUrls.length).toFixed(3)}us`);

  const coldNonBlock = bench(
    'cold cache, non-block URLs (50K) -> sync false (no roundtrip)',
    () => {
      const i = freshInterceptor();
      let undecided = 0;
      for (const u of nonBlockUrls) {
        if (i.checkSync(u) === undefined) undecided++;
      }
      // We expect ~bloom FP rate to be undecided.
    },
    { iters: 5 },
  );
  reportBench(coldNonBlock);
  row('  per-call', `${(coldNonBlock.median * 1000 / nonBlockUrls.length).toFixed(3)}us`);

  // Hot cache: warm the cache once, then re-bench.
  const warm = freshInterceptor();
  for (const u of nonBlockUrls) warm.checkSync(u); // populates cache with `false`s
  const hotNonBlock = bench(
    'hot cache, non-block URLs (50K) -> cache hit',
    () => {
      for (const u of nonBlockUrls) warm.checkSync(u);
    },
    { iters: 5 },
  );
  reportBench(hotNonBlock);
  row('  per-call', `${(hotNonBlock.median * 1000 / nonBlockUrls.length).toFixed(3)}us`);

  // ---------- Mixed workload — what one page actually looks like ----------
  // Typical news/social page: ~200 sub-resources across ~30 unique
  // hosts. With Hagezi+EasyList loaded and no per-site exemptions, a
  // representative ad-heavy page sees roughly 5–10% of *requests* hit
  // the bloom (most blocked CDNs are reused across many requests).
  console.log('\nMixed workload (200 reqs, 30 unique hosts, bloom hit rate ~10%):');
  const HIT_FRAC = 0.10;
  const REQS = 200;
  const HOSTS = 30;
  const next = rng(77);
  const pageHosts = [];
  const hitCount = Math.round(HOSTS * HIT_FRAC);
  for (let i = 0; i < hitCount; i++) {
    pageHosts.push(blockHostsAll[(next() * blockHostsAll.length) | 0]);
  }
  for (let i = hitCount; i < HOSTS; i++) {
    pageHosts.push(nonBlockHosts[(next() * nonBlockHosts.length) | 0]);
  }
  const pageStream = [];
  for (let i = 0; i < REQS; i++) {
    pageStream.push(`https://${pageHosts[(next() * pageHosts.length) | 0]}/r${i}`);
  }

  let lastRoundtrips = 0;
  let lastSynced = 0;
  const page = bench(
    'one page (200 reqs, fresh interceptor)',
    () => {
      const i = freshInterceptor();
      let roundtrips = 0;
      let synced = 0;
      for (const u of pageStream) {
        const r = i.checkSync(u);
        if (r === undefined) roundtrips++;
        else synced++;
      }
      lastRoundtrips = roundtrips;
      lastSynced = synced;
    },
    { iters: 7 },
  );
  reportBench(page);
  row('  decisions: sync vs roundtrip',
      `${lastSynced} sync, ${lastRoundtrips} roundtrip ` +
      `(${(100 * lastRoundtrips / pageStream.length).toFixed(1)}% Dart hit)`);

  // ---------- Summary ----------
  console.log('\nNotes:');
  console.log('  * Block per-call cost = 1 bloom probe (k FNV-1a hashes).');
  console.log('    Non-block = 1 probe per label up to the public suffix —');
  console.log('    that is where suffix-walk cost shows up.');
  console.log('  * "% Dart hit" in the mixed workload is the RPC rate that');
  console.log('    hits blockCheck on iOS/macOS. Multiply by the per-call');
  console.log('    bridge cost from integration_test/js_bridge_benchmark_test');
  console.log('    to estimate per-page roundtrip wall-clock.');
  console.log('  * Sync hot-cache cost is steady-state on a long-lived tab,');
  console.log('    once every host has been seen at least once.');
}

main();
