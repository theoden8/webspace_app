// Validates the hostless-rule token prefilter used by the iOS/macOS JS
// sub-resource interceptor (webview.dart). fnv1a / the bloom build /
// urlMaybeGeneric are copied from the interceptor and BloomFilter so the
// test exercises the exact algorithm; if you change either side, change
// it here too.
//
// Two properties matter, and they're tested differently:
//   * No false NEGATIVE (the safety property): a stored token is ALWAYS
//     found for a URL the rule matches. Tested against the real bloom —
//     positives are exact, bloom false positives can't break this.
//   * Tokenization logic (min length, token boundaries): tested against
//     an EXACT set, not the bloom, because a bloom false positive (a
//     harmless extra round-trip) would otherwise make "miss" assertions
//     flaky. The interceptor tolerates false positives by design.

const test = require('node:test');
const assert = require('node:assert/strict');

// ---- copied from lib/services/bloom_filter.dart (BloomFilter.build) ----
function fnv1a(s, seed) {
  let h = seed >>> 0;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}
function buildBloom(items, fpRate = 0.02) {
  const arr = [...new Set(items)];
  const n = arr.length;
  if (n === 0) return { bits: new Uint8Array(8), bitCount: 64, k: 1 };
  const ln2 = Math.LN2;
  const m = Math.ceil((-n * Math.log(fpRate)) / (ln2 * ln2));
  const byteCount = Math.ceil(m / 8);
  const bitCount = byteCount * 8;
  const k = Math.min(16, Math.max(1, Math.round((m / n) * ln2)));
  const bits = new Uint8Array(byteCount);
  for (const item of arr) {
    const h1 = fnv1a(item, 0x811c9dc5);
    const h2 = fnv1a(item, 0xcbf29ce4);
    for (let i = 0; i < k; i++) {
      const pos = ((h1 + i * h2) >>> 0) % bitCount;
      bits[pos >> 3] |= 1 << (pos & 7);
    }
  }
  return { bits, bitCount, k };
}
function bloomMember(b) {
  return function (tok) {
    const h1 = fnv1a(tok, 0x811c9dc5);
    const h2 = fnv1a(tok, 0xcbf29ce4);
    for (let i = 0; i < b.k; i++) {
      const pos = ((h1 + i * h2) >>> 0) % b.bitCount;
      if ((b.bits[pos >> 3] & (1 << (pos & 7))) === 0) return false;
    }
    return true;
  };
}

// ---- urlMaybeGeneric, copied from the interceptor (webview.dart) ----
// `member(tok)` stands in for the embedded tokenHit(); the membership
// backend is injected so logic tests can use an exact set.
function urlMaybeGeneric(url, member) {
  const s = url.toLowerCase();
  const n = s.length > 2048 ? 2048 : s.length;
  let start = -1;
  for (let i = 0; i <= n; i++) {
    const c = i < n ? s.charCodeAt(i) : 0;
    const alnum = (c >= 48 && c <= 57) || (c >= 97 && c <= 122);
    if (alnum) {
      if (start < 0) start = i;
    } else {
      if (start >= 0) {
        if (i - start >= 3 && member(s.substring(start, i))) return true;
        start = -1;
      }
    }
  }
  return false;
}
const exact = (set) => (tok) => set.has(tok);

test('SAFETY: a stored token is always found in a matching URL (real bloom)', () => {
  // Realistic-sized token set so the positive lookups exercise the real
  // hashing; positives are exact regardless of bloom size.
  const tokens = [];
  for (let i = 0; i < 300; i++) tokens.push('filler' + i);
  tokens.push('banner', 'tracker', 'conversion', 'doubleclicktrack');
  const member = bloomMember(buildBloom(tokens));
  assert.equal(urlMaybeGeneric('https://news.example.com/ads/banner-300.png', member), true);
  assert.equal(urlMaybeGeneric('http://x.com/tracker.gif?u=1', member), true);
  assert.equal(urlMaybeGeneric('https://g.example/pagead/conversion/9', member), true);
  assert.equal(urlMaybeGeneric('https://cdn.x/js/doubleclicktrack.min.js', member), true);
});

test('a URL with none of the tokens is allowed', () => {
  const member = exact(new Set(['banner', 'tracker', 'conversion']));
  assert.equal(urlMaybeGeneric('https://news.example.com/articles/world.html', member), false);
  assert.equal(urlMaybeGeneric('https://cdn.example.com/css/main.css', member), false);
});

test('tokens shorter than 3 chars are never checked', () => {
  // Even with "ad" in the set, a 2-char path segment is skipped.
  const member = exact(new Set(['ad']));
  assert.equal(urlMaybeGeneric('https://sld.tld/ad/x', member), false);
});

test('match is on alnum-token boundaries, not arbitrary substrings', () => {
  const member = exact(new Set(['adserver']));
  assert.equal(urlMaybeGeneric('https://x.com/adserver/t.js', member), true);
  // embedded in a larger token -> not a token -> miss (mirrors the
  // engine's own tokenized candidate selection).
  assert.equal(urlMaybeGeneric('https://x.com/myadserverx/t.js', member), false);
});

test('empty token set never flags (hostless prefilter disabled)', () => {
  const member = () => false;
  assert.equal(urlMaybeGeneric('https://x.com/ads/banner-1.png', member), false);
});
