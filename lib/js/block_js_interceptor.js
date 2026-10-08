// Blocks fetch, XHR and src/href loads the site's DNS level or filter lists
// refuse. A Bloom filter of both lists (`getBlockBloom`) answers misses
// synchronously, so the common case never waits on a microtask; a hit asks
// `blockCheck`, whose answer is `false` (allow), `true` (block) or a
// `data:` URL to load instead (`$redirect=`).
//
// WebKit (iOS/macOS) only. Android blocks sub-resources natively in
// FastSubresourceInterceptor; WKContentRuleList cannot hold the lists, so this
// runs in every frame of the page.
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

  // Sync-only check. Returns:
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

  function checkAsync(url) {
    // Capture cacheability synchronously: pendingCacheable is set by the
    // checkSync call that immediately preceded this one, and a later
    // request could overwrite it before this promise resolves.
    var cacheable = pendingCacheable;
    if (!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler)) {
      return Promise.resolve(false);
    }
    return window.flutter_inappwebview.callHandler('blockCheck', url).then(function(decision) {
      // A redirect is the verdict of a path rule, so it is never this
      // host's, and coercing it to a bool would drop the request the rule
      // meant to serve a stub to (CB-010).
      if (isRedirect(decision)) return decision;
      if (cacheable) {
        try {
          var host = new URL(url).hostname;
          if (host) cachePut(host, !!decision);
        } catch (e) {}
      }
      return !!decision;
    });
  }

  function loadBloom() {
    if (!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler)) {
      setTimeout(loadBloom, 50);
      return;
    }
    window.flutter_inappwebview.callHandler('getBlockBloom').then(function(map) {
      if (!map) return;
      var bytes = map.bits;
      bloomBits = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      bloomBitCount = map.bitCount;
      bloomK = map.k;
      if (map.tokenBits && map.tokenBitCount) {
        tokenBits = map.tokenBits instanceof Uint8Array
            ? map.tokenBits : new Uint8Array(map.tokenBits);
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

  // Async decision encoding (returned by callHandler('blockCheck')):
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
      var url = typeof input === 'string' ? input : (input && input.url);
      var sync = checkSync(url);
      if (sync === false) return origFetch.call(this, input, init);
      if (sync === true) return Promise.reject(new TypeError('Blocked: ' + url));
      var self = this;
      return checkAsync(url).then(function(decision) {
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
    this.__dnsBlockUrl = url;
    return origOpen.apply(this, arguments);
  };
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    var url = this.__dnsBlockUrl;
    var sync = checkSync(url);
    if (sync === false) return origSend.apply(this, arguments);
    if (sync === true) { try { this.abort(); } catch (e) {} return; }
    var self = this;
    var args = arguments;
    checkAsync(url).then(function(decision) {
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
        var sync = checkSync(value);
        if (sync === false) { origSet.call(this, value); return; }
        if (sync === true) { return; }
        var el = this;
        checkAsync(value).then(function(decision) {
          if (isRedirect(decision)) origSet.call(el, decision);
          else if (!decision) origSet.call(el, value);
        });
      }
    });
  }
  patchSetter(HTMLImageElement.prototype, 'src');
  patchSetter(HTMLScriptElement.prototype, 'src');
  patchSetter(HTMLLinkElement.prototype, 'href');
  patchSetter(HTMLIFrameElement.prototype, 'src');

  // MutationObserver for statically-parsed HTML elements. Bloom-miss
  // path is a no-op (the element is allowed to keep the attribute);
  // only confirmed-blocked elements are stripped (or rewritten when
  // the engine offers a redirect body).
  function checkElement(el) {
    var attr = null;
    if (el.tagName === 'IMG' || el.tagName === 'SCRIPT' || el.tagName === 'IFRAME') attr = 'src';
    else if (el.tagName === 'LINK') attr = 'href';
    if (!attr) return;
    var url = el.getAttribute(attr);
    if (!url || url.indexOf('http') !== 0) return;
    var sync = checkSync(url);
    if (sync === false) return; // allowed, leave element alone
    if (sync === true) {
      el.removeAttribute(attr);
      if (el.parentNode) el.parentNode.removeChild(el);
      return;
    }
    checkAsync(url).then(function(decision) {
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
})();
