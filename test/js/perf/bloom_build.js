// JS-side bloom builder, mirroring `lib/services/bloom_filter.dart`.
// Used to seed the benchmark filter from a synthetic blocklist so we
// don't have to ship a real Hagezi list in the repo just to run perf.

'use strict';

const { fnv1a } = require('./old_interceptor');

function buildBloom(items, fpRate = 0.05) {
  const n = items.length;
  if (n === 0) return { bits: new Uint8Array(8), bitCount: 64, k: 1 };
  const ln2 = Math.LN2;
  const m = Math.ceil((-n * Math.log(fpRate)) / (ln2 * ln2));
  const byteCount = Math.ceil(m / 8);
  const bitCount = byteCount * 8;
  const k = Math.max(1, Math.min(16, Math.round((m / n) * ln2)));
  const bits = new Uint8Array(byteCount);
  for (const item of items) {
    const h1 = fnv1a(item, 0x811C9DC5);
    const h2 = fnv1a(item, 0xCBF29CE4);
    for (let i = 0; i < k; i++) {
      const pos = ((h1 + i * h2) >>> 0) % bitCount;
      bits[pos >> 3] |= 1 << (pos & 7);
    }
  }
  return { bits, bitCount, k };
}

module.exports = { buildBloom };
