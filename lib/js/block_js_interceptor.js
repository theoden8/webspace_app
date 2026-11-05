// Blocks fetch, XHR and src/href loads the site's DNS level or filter lists
// refuse. A Bloom filter of both lists (`getBlockBloom`) answers misses
// synchronously, so the common case never waits on a microtask; a hit asks
// `blockCheckBatch`, whose answer for each URL is `false` (allow), `true`
// (block) or a `data:` URL to load instead (`$redirect=`).
//
// Each ask names the request's type in the engine's words and whether
// WebKit had already issued it (an element in the page), which decides what
// the app counts (CB-012). What the page blocks from its cache, or sees fail,
// goes to `blockRecordBatch` for the app to count without an answer, and so
// do the blocks WebKit reports itself where it can (`__wsWebKitBlocked`,
// CONFIG.webKitReports, CB-023).
//
// WebKit (iOS, macOS, Linux) only. Android blocks sub-resources natively in
// FastSubresourceInterceptor. The content rule lists (CB-020) carry no
// redirects and are an experiment on Linux, so this runs in every frame of
// the page.
(function() {
  var bloomReady = false;
  var bloomBits = null;
  var bloomBitCount = 0;
  var bloomK = 0;

  // Second bloom for hostless network rules (path/substring), keyed by
  // the rules' literal tokens. The host bloom can't prefilter a rule
  // that matches on path, so without this a `/ads/track.js`-style rule
  // never fires on iOS/macOS (bloom miss == hard allow). hasGeneric is
  // true when any such rule is loaded; genericFallback is true when the
  // lists also carry rules we can't tokenize (regex, sub-3-char tokens),
  // which force a Dart round-trip on every host-bloom miss.
  var tokenBits = null;
  var tokenBitCount = 0;
  var tokenK = 0;
  var hasGeneric = false;
  var genericFallback = false;
  // Set by checkSync, read synchronously by checkAsync: whether the
  // round-trip's verdict may be cached by host. Host-level matches
  // (host bloom / DNS) are cacheable; a token-driven path match is not,
  // since a different path on the same host can have a different verdict.
  var pendingCacheable = true;

  function fnv1a(s, seed) {
    var h = seed >>> 0;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h >>> 0;
  }

  function bloomContains(s) {
    if (!bloomReady) return true;
    var h1 = fnv1a(s, 0x811C9DC5);
    var h2 = fnv1a(s, 0xCBF29CE4);
    for (var i = 0; i < bloomK; i++) {
      var pos = ((h1 + i * h2) >>> 0) % bloomBitCount;
      if ((bloomBits[pos >> 3] & (1 << (pos & 7))) === 0) return false;
    }
    return true;
  }

  function maybeBlocked(host) {
    if (bloomContains(host)) return true;
    // Suffix walk without parts.slice().join() per level — peel labels
    // from the left by tracking a single dot index.
    var dot = host.indexOf('.');
    while (dot >= 0 && dot < host.length - 1) {
      var parent = host.substring(dot + 1);
      if (parent.indexOf('.') < 0) break;
      if (bloomContains(parent)) return true;
      dot = host.indexOf('.', dot + 1);
    }
    return false;
  }

  function tokenHit(tok) {
    if (!tokenBits) return false;
    var h1 = fnv1a(tok, 0x811C9DC5);
    var h2 = fnv1a(tok, 0xCBF29CE4);
    for (var i = 0; i < tokenK; i++) {
      var pos = ((h1 + i * h2) >>> 0) % tokenBitCount;
      if ((tokenBits[pos >> 3] & (1 << (pos & 7))) === 0) return false;
    }
    return true;
  }

  // Tokenize the URL on runs of [a-z0-9] (the finest split, so never
  // coarser than the engine's own tokenizer — guarantees no false
  // negative) and return true if any >=3-char token is in the token
  // bloom. A hit means a hostless rule MIGHT match, so we let Dart
  // adjudicate the full URL. Pure string scan, no allocation per token
  // beyond the substring on an actual hit candidate.
  function urlMaybeGeneric(url) {
    var s = url.toLowerCase();
    var n = s.length > 2048 ? 2048 : s.length;
    var start = -1;
    for (var i = 0; i <= n; i++) {
      var c = i < n ? s.charCodeAt(i) : 0;
      var alnum = (c >= 48 && c <= 57) || (c >= 97 && c <= 122);
      if (alnum) {
        if (start < 0) start = i;
      } else {
        if (start >= 0) {
          if (i - start >= 3 && tokenHit(s.substring(start, i))) return true;
          start = -1;
        }
      }
    }
    return false;
  }

  // Cache. Capacity 500 covers the typical page header set; FIFO eviction
  // when full. Map-of-bools instead of two parallel objects so we keep
  // per-host RAM at one entry not two — important on iOS where every
  // long-running tab keeps this state alive.
  var hostCache = Object.create(null);     // host -> true (blocked) | false (allowed)
  var hostOrder = [];                       // FIFO order
  var MAX_CACHE = 500;
  function cacheGet(host) { return hostCache[host]; }
  function cachePut(host, blocked) {
    if (host in hostCache) { hostCache[host] = blocked; return; }
    hostCache[host] = blocked;
    hostOrder.push(host);
    if (hostOrder.length > MAX_CACHE) {
      var old = hostOrder.shift();
      delete hostCache[old];
    }
  }

  // The http(s) URL a request for [raw] goes to, resolved as the page
  // resolves it, or null for one the lists never name (data:, blob:, a
  // value that does not parse). A first-party tracker is usually a
  // relative path (`fetch('/rest/event/analytics')`), and a page may pass
  // a URL object, so the raw value is not what the rules match.
  function absolute(raw) {
    if (raw == null || raw === '') return null;
    var s = String(raw);
    if (s.indexOf('https://') === 0 || s.indexOf('http://') === 0) return s;
    var u;
    try { u = new URL(s, document.baseURI); } catch (e) { return null; }
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.href : null;
  }

  // Sync-only check of an absolute URL. Returns:
  //   true  → known blocked (skip request)
  //   false → known allowed (proceed synchronously)
  //   undefined → decision needs async Dart confirmation
  // The caller is responsible for handling the undefined case via
  // checkAsync. Keeping the sync path branchless and microtask-free is
  // what makes property-setter patches not stall image loads.
  function checkSync(url) {
    if (!url || typeof url !== 'string' || url.charCodeAt(0) !== 104) return false; // 'h'
    if (url.indexOf('http') !== 0) return false;
    var host;
    try { host = new URL(url).hostname; } catch (e) { return false; }
    if (!host) return false;
    var cached = cacheGet(host);
    if (cached === false) return false;
    if (cached === true) return true;
    if (!bloomReady) { pendingCacheable = true; return undefined; } // warming up
    if (maybeBlocked(host)) {
      pendingCacheable = true; // host-level match — verdict is per host
      return undefined; // bloom hit — Dart must adjudicate
    }
    // Host bloom miss. With no hostless rules loaded this is a definite
    // allow (and cacheable by host, the common fast path). With hostless
    // rules present we can't cache by host — a path rule may match one
    // URL on this host and not another — so re-evaluate per request:
    // tokenize and only round-trip on a token hit.
    if (hasGeneric) {
      if (genericFallback || urlMaybeGeneric(url)) {
        pendingCacheable = false; // path-level — must not cache by host
        return undefined;
      }
      return false; // no generic token matched — allow, but don't cache
    }
    cachePut(host, false);
    return false;
  }

  function bridge() {
    return !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);
  }

  // Every URL this document asked the app about or blocked from its cache,
  // so a load error on one of them is not counted a second time. Bounded: a
  // long-lived page starts over.
  var asked = Object.create(null);
  var askedCount = 0;
  function remember(url) {
    if (asked[url]) return;
    if (askedCount >= 2000) { asked = Object.create(null); askedCount = 0; }
    asked[url] = 1;
    askedCount++;
  }

  // The checks one burst of requests asks (an image grid, a chunk
  // waterfall's next step) go to Dart as one call: each round trip crosses
  // the bridge twice, on iOS on the main thread.
  var pendingChecks = [];
  function flushChecks() {
    var batch = pendingChecks;
    pendingChecks = [];
    var asks = [];
    for (var i = 0; i < batch.length; i++) {
      asks.push({url: batch[i].url, type: batch[i].type, issued: batch[i].issued});
    }
    window.flutter_inappwebview.callHandler('blockCheckBatch', asks).then(function(decisions) {
      for (var j = 0; j < batch.length; j++) {
        batch[j].resolve(settle(batch[j], decisions ? decisions[j] : false));
      }
    }, function(e) {
      for (var j = 0; j < batch.length; j++) batch[j].reject(e);
    });
  }

  function settle(check, decision) {
    // A redirect is the verdict of a path rule, so it is never this
    // host's, and coercing it to a bool would drop the request the rule
    // meant to serve a stub to (CB-010).
    if (isRedirect(decision)) return decision;
    if (check.cacheable) {
      try {
        var host = new URL(check.url).hostname;
        if (host) cachePut(host, !!decision);
      } catch (e) {}
    }
    return !!decision;
  }

  function checkAsync(url, type, issued) {
    // Capture cacheability synchronously: pendingCacheable is set by the
    // checkSync call that immediately preceded this one, and a later
    // request could overwrite it before this promise resolves.
    var cacheable = pendingCacheable;
    remember(url);
    if (!bridge()) return Promise.resolve(false);
    return new Promise(function(resolve, reject) {
      if (pendingChecks.length === 0) Promise.resolve().then(flushChecks);
      pendingChecks.push({
        url: url, type: type, issued: issued, cacheable: cacheable,
        resolve: resolve, reject: reject,
      });
    });
  }

  // What the page reports without asking: `cached` (a block the host cache
  // answered), `failed` (a load error on a URL the Bloom filter names) and
  // `webkit` (a block WebKit's rule lists report). Batched, unanswered.
  var pendingRecords = [];
  var RECORD_MS = 250;
  function report(entry) {
    if (!bridge()) return;
    if (pendingRecords.length === 0) setTimeout(flushRecords, RECORD_MS);
    pendingRecords.push(entry);
  }
  function flushRecords() {
    // A load error can fire before the observer asks about the element that
    // failed; once asked, the ask is the request's one count.
    var batch = [];
    for (var i = 0; i < pendingRecords.length; i++) {
      var e = pendingRecords[i];
      if (e.why !== 'failed' || !asked[e.url]) batch.push(e);
    }
    pendingRecords = [];
    if (batch.length) window.flutter_inappwebview.callHandler('blockRecordBatch', batch);
  }
  function blockedFromCache(url, type, issued) {
    remember(url);
    report({url: url, type: type, issued: issued, why: 'cached'});
  }

  function fromBase64(s) {
    var bin = atob(s);
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function loadBloom() {
    if (!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler)) {
      setTimeout(loadBloom, 50);
      return;
    }
    window.flutter_inappwebview.callHandler('getBlockBloom').then(function(map) {
      if (!map) return;
      bloomBits = fromBase64(map.bits64);
      bloomBitCount = map.bitCount;
      bloomK = map.k;
      if (map.tokenBits64 && map.tokenBitCount) {
        tokenBits = fromBase64(map.tokenBits64);
        tokenBitCount = map.tokenBitCount;
        tokenK = map.tokenK;
      } else {
        tokenBits = null;
      }
      genericFallback = !!map.genericFallback;
      hasGeneric = !!map.hasGeneric;
      // Under hostless (path) rules a host-level "allowed" verdict can't
      // be trusted to skip the per-request token check, so drop any
      // allows cached during warmup. Blocks are host-level and safe.
      if (hasGeneric) {
        for (var ch in hostCache) {
          if (!hostCache[ch]) delete hostCache[ch];
        }
      }
      // The response carries no host list. The app-wide domain-decision
      // cache used to be seeded in here as a warm start, but any page can
      // call this handler and there is no origin allowlist — that made
      // every other site's browsing history readable from page JS. The
      // bloom answers the same question; a cold hostCache only costs a
      // Dart round-trip on the first bloom hit per host.
      bloomReady = true;
    });
  }
  loadBloom();

  // The app's lists changed under this document: verdicts cached against
  // the old ones go, and the old bloom answers until the new one lands.
  window.__wsReloadBlockBloom = function() {
    hostCache = Object.create(null);
    hostOrder = [];
    loadBloom();
  };

  // Async decision encoding (each entry of callHandler('blockCheckBatch')):
  //   false       — allow
  //   true        — block (drop)
  //   <string>    — block + redirect; string is a `data:` URL to
  //                 swap the request with. Engine's $redirect= path.
  // checkSync only knows bool (bloom prefilter answers host membership,
  // not redirect specifics) — redirect lookup always goes through Dart.
  function isRedirect(d) { return typeof d === 'string' && d.indexOf('data:') === 0; }

  // fetch — sync fast-path on misses, async only on bloom hits.
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function(input, init) {
      var url = absolute(input && typeof input.url === 'string' ? input.url : input);
      var sync = checkSync(url);
      if (sync === false) return origFetch.call(this, input, init);
      if (sync === true) {
        blockedFromCache(url, 'xhr', false);
        return Promise.reject(new TypeError('Blocked: ' + url));
      }
      var self = this;
      return checkAsync(url, 'xhr', false).then(function(decision) {
        if (isRedirect(decision)) return origFetch.call(self, decision, init);
        if (decision) return Promise.reject(new TypeError('Blocked: ' + url));
        return origFetch.call(self, input, init);
      });
    };
  }

  // XMLHttpRequest. Redirect can't easily swap the URL after open();
  // chromium has already configured the request. Drop the XHR
  // entirely on a redirect decision — equivalent observable
  // behaviour to a plain block. Better-engineered redirect for XHR
  // would intercept earlier (at open()) and re-issue against the
  // data URL, but XHR is rare for tracker scripts so skip.
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__dnsBlockUrl = absolute(url);
    return origOpen.apply(this, arguments);
  };
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    var url = this.__dnsBlockUrl;
    var sync = checkSync(url);
    if (sync === false) return origSend.apply(this, arguments);
    if (sync === true) {
      blockedFromCache(url, 'xhr', false);
      try { this.abort(); } catch (e) {}
      return;
    }
    var self = this;
    var args = arguments;
    checkAsync(url, 'xhr', false).then(function(decision) {
      if (decision) { try { self.abort(); } catch (e) {} return; }
      origSend.apply(self, args);
    });
  };

  // Property setters for src/href. CRITICAL that the bloom-miss path is
  // synchronous: wrapping `el.src = url` in `Promise.resolve().then(set)`
  // delays every image load by one microtask. On a typical e-commerce
  // page with 200 product images that's 200 microtasks — visible
  // jitter and dropped scroll frames.
  function patchSetter(proto, attr) {
    var desc = Object.getOwnPropertyDescriptor(proto, attr);
    if (!desc || !desc.set) return;
    var origSet = desc.set;
    Object.defineProperty(proto, attr, {
      configurable: true,
      enumerable: desc.enumerable,
      get: desc.get,
      set: function(value) {
        var url = absolute(value);
        var sync = checkSync(url);
        if (sync === false) { origSet.call(this, value); return; }
        var type = typeOf(this);
        if (sync === true) { blockedFromCache(url, type, false); return; }
        var el = this;
        checkAsync(url, type, false).then(function(decision) {
          if (isRedirect(decision)) origSet.call(el, decision);
          else if (!decision) origSet.call(el, value);
        });
      }
    });
  }
  // The request type of an element's load, in the engine's words (the same
  // names Android's interceptor derives from Sec-Fetch-Dest).
  function typeOf(el) {
    switch (el.tagName) {
      case 'IMG': return 'image';
      case 'SCRIPT': return 'script';
      case 'LINK': return /(^|\s)stylesheet(\s|$)/i.test(el.rel || '') ? 'stylesheet' : 'other';
      case 'IFRAME': case 'FRAME': case 'EMBED': case 'OBJECT': return 'subdocument';
      case 'VIDEO': case 'AUDIO': case 'SOURCE': case 'TRACK': return 'media';
      case 'INPUT': return 'image';
      default: return 'other';
    }
  }

  patchSetter(HTMLImageElement.prototype, 'src');
  patchSetter(HTMLScriptElement.prototype, 'src');
  patchSetter(HTMLLinkElement.prototype, 'href');
  patchSetter(HTMLIFrameElement.prototype, 'src');

  // MutationObserver for statically-parsed HTML elements. Bloom-miss
  // path is a no-op (the element is allowed to keep the attribute);
  // only confirmed-blocked elements are stripped (or rewritten when
  // the engine offers a redirect body).
  //
  // By the time the observer sees an element WebKit has issued its request,
  // so its verdict counts only as the app's record of what WebKit's own
  // lists did with it (`issued`).
  function checkElement(el) {
    var attr = null;
    if (el.tagName === 'IMG' || el.tagName === 'SCRIPT' || el.tagName === 'IFRAME') attr = 'src';
    else if (el.tagName === 'LINK') attr = 'href';
    if (!attr) return;
    var url = absolute(el.getAttribute(attr));
    if (!url) return;
    var sync = checkSync(url);
    if (sync === false) return; // allowed, leave element alone
    var type = typeOf(el);
    if (sync === true) {
      blockedFromCache(url, type, true);
      el.removeAttribute(attr);
      if (el.parentNode) el.parentNode.removeChild(el);
      return;
    }
    checkAsync(url, type, true).then(function(decision) {
      if (isRedirect(decision)) {
        el.setAttribute(attr, decision);
        return;
      }
      if (decision) {
        el.removeAttribute(attr);
        if (el.parentNode) el.parentNode.removeChild(el);
      }
    });
  }
  var mo = new MutationObserver(function(mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var added = mutations[i].addedNodes;
      for (var j = 0; j < added.length; j++) {
        var node = added[j];
        if (node.nodeType !== 1) continue;
        checkElement(node);
        if (node.querySelectorAll) {
          var els = node.querySelectorAll('img, script, link, iframe');
          for (var k = 0; k < els.length; k++) checkElement(els[k]);
        }
      }
    }
  });
  function startObserving() {
    if (document.documentElement) {
      mo.observe(document.documentElement, {childList: true, subtree: true});
    } else {
      setTimeout(startObserving, 10);
    }
  }
  startObserving();

  // A load error on an element whose URL the Bloom filter names and this
  // document never asked about: a srcset or <source> pick, media, an
  // attribute changed in place. WebKit's lists may have blocked it, or the
  // network failed it; the app counts it only if a list names it. Off where
  // WebKit reports its blocks itself, which would count it twice.
  function failedLoad(event) {
    var el = event.target;
    if (!el || el.nodeType !== 1) return;
    var raw = el.currentSrc || el.src || el.href || el.data;
    var url = absolute(typeof raw === 'string' ? raw : null);
    if (!url || asked[url]) return;
    if (checkSync(url) === false) return;
    report({url: url, type: typeOf(el), issued: true, why: 'failed'});
  }
  if (!CONFIG.webKitReports) {
    document.addEventListener('error', failedLoad, true);
  }

  // Native code hands the page the URLs WebKit's rule lists blocked (CB-023);
  // they reach the app like the page's own reports. A page that forges a
  // call records nothing a list does not name.
  window.__wsWebKitBlocked = function(urls) {
    if (!CONFIG.webKitReports || !urls) return;
    for (var i = 0; i < urls.length; i++) {
      if (typeof urls[i] === 'string') report({url: urls[i], type: '', issued: true, why: 'webkit'});
    }
  };
})();
