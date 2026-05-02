// Old (pre-rewrite) iOS JS interceptor logic, kept here for relative
// benchmarking. The shape mirrors what was inlined in
// `lib/services/webview.dart` before the sync-fast-path landed:
//
//   * `check(url)` always returns a Promise — even on bloom miss the
//     caller pays a microtask roundtrip via `.then`.
//   * `maybeBlocked(host)` walks the suffix hierarchy with
//     `parts = host.split('.')` + `parts.slice(i).join('.')` per level,
//     allocating a fresh array + string per parent.
//   * Property setter wraps origSet in `check(value).then(b => if(!b)
//     origSet.call(el, value))` — every `<img>.src = url` pays a
//     microtask delay even when the bloom misses.
//
// This is a pure CPU/JS-runtime simulation of the cost: no jsdom DOM,
// no real fetch. The point is to compare the algorithmic / scheduling
// overhead, not to reproduce the network behaviour.

'use strict';

function fnv1a(s, seed) {
  let h = seed >>> 0;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

function makeOldInterceptor({ bloomBits, bloomBitCount, bloomK, callHandler }) {
  let bloomReady = bloomBits != null;

  function bloomContains(s) {
    if (!bloomReady) return true;
    const h1 = fnv1a(s, 0x811C9DC5);
    const h2 = fnv1a(s, 0xCBF29CE4);
    for (let i = 0; i < bloomK; i++) {
      const pos = ((h1 + i * h2) >>> 0) % bloomBitCount;
      if ((bloomBits[pos >> 3] & (1 << (pos & 7))) === 0) return false;
    }
    return true;
  }

  // Old suffix walk: allocates `parts` array + joinToString per level.
  function maybeBlocked(host) {
    if (bloomContains(host)) return true;
    const parts = host.split('.');
    for (let i = 1; i < parts.length - 1; i++) {
      if (bloomContains(parts.slice(i).join('.'))) return true;
    }
    return false;
  }

  const allowedCache = Object.create(null);
  const blockedCache = Object.create(null);
  const cacheKeys = [];
  const MAX_CACHE = 500;

  function cacheResult(host, blocked) {
    if (blocked) blockedCache[host] = 1;
    else allowedCache[host] = 1;
    cacheKeys.push(host);
    if (cacheKeys.length > MAX_CACHE) {
      const old = cacheKeys.shift();
      delete allowedCache[old];
      delete blockedCache[old];
    }
  }

  function check(url) {
    if (!url || typeof url !== 'string' || !url.startsWith('http')) {
      return Promise.resolve(false);
    }
    let host;
    try { host = new URL(url).hostname; } catch (e) { return Promise.resolve(false); }
    if (allowedCache[host]) return Promise.resolve(false);
    if (blockedCache[host]) return Promise.resolve(true);
    if (!maybeBlocked(host)) {
      cacheResult(host, false);
      // Old behaviour also fires `blockResourceLoaded` here; the
      // microtask cost is what we actually care about for this bench.
      return Promise.resolve(false);
    }
    return callHandler('blockCheck', url).then((blocked) => {
      cacheResult(host, !!blocked);
      return !!blocked;
    });
  }

  return { check, maybeBlocked, bloomContains };
}

module.exports = { makeOldInterceptor, fnv1a };
