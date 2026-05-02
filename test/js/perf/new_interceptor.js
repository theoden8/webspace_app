// New iOS JS interceptor logic, mirroring the rewrite in
// `lib/services/webview.dart` (the `block_js_interceptor` user script).
//
//   * `checkSync(url)` returns true / false / undefined — no Promise
//     wrapping on the bloom-miss / cache-hit fast path.
//   * Suffix walk uses `host.indexOf('.', dot+1)` + `substring`, no
//     `split('.')` array allocation per level.
//   * Cache is one map keyed by host (not two parallel objects), with
//     FIFO eviction.
//
// Standalone for benching — kept in sync with webview.dart manually.

'use strict';

const { fnv1a } = require('./old_interceptor');

function makeNewInterceptor({ bloomBits, bloomBitCount, bloomK, callHandler }) {
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

  // New suffix walk: no array allocation, peel labels via indexOf.
  function maybeBlocked(host) {
    if (bloomContains(host)) return true;
    let dot = host.indexOf('.');
    while (dot >= 0 && dot < host.length - 1) {
      const parent = host.substring(dot + 1);
      if (parent.indexOf('.') < 0) break;
      if (bloomContains(parent)) return true;
      dot = host.indexOf('.', dot + 1);
    }
    return false;
  }

  const hostCache = Object.create(null);
  const hostOrder = [];
  const MAX_CACHE = 500;

  function cacheGet(host) { return hostCache[host]; }
  function cachePut(host, blocked) {
    if (host in hostCache) { hostCache[host] = blocked; return; }
    hostCache[host] = blocked;
    hostOrder.push(host);
    if (hostOrder.length > MAX_CACHE) {
      const old = hostOrder.shift();
      delete hostCache[old];
    }
  }

  function checkSync(url) {
    if (!url || typeof url !== 'string' || url.charCodeAt(0) !== 104) return false;
    if (url.indexOf('http') !== 0) return false;
    let host;
    try { host = new URL(url).hostname; } catch (e) { return false; }
    if (!host) return false;
    const cached = cacheGet(host);
    if (cached === false) return false;
    if (cached === true) return true;
    if (!bloomReady) return undefined;
    if (!maybeBlocked(host)) {
      cachePut(host, false);
      return false;
    }
    return undefined;
  }

  function checkAsync(url) {
    return callHandler('blockCheck', url).then((blocked) => {
      try {
        const host = new URL(url).hostname;
        if (host) cachePut(host, !!blocked);
      } catch (e) {}
      return !!blocked;
    });
  }

  function check(url) {
    const sync = checkSync(url);
    if (sync !== undefined) return Promise.resolve(sync);
    return checkAsync(url);
  }

  return { check, checkSync, checkAsync, maybeBlocked, bloomContains };
}

module.exports = { makeNewInterceptor };
