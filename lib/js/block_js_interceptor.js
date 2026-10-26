// Blocks fetch, XHR and src/href loads the site's DNS level or filter lists
// refuse. A Bloom filter of both lists (`getBlockBloom`) answers misses
// synchronously, so the common case never waits on a microtask; a hit asks
// `blockCheck`, whose answer is `false` (allow), `true` (block) or a
// `data:` URL to load instead (`$redirect=`), and is kept for the next
// request with the same URL.
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

  // This document's answers from `blockCheck`, keyed by the one argument it is
  // sent (CB-020). Dart judges that URL against this frame's origin, which the
  // bridge attaches and a document never changes, and reads nothing else that
  // varies by request, so an equal key is an equal question. Never keyed by
  // host: a path rule (`||youtube.com/pagead/`) answers two URLs on one host
  // differently. An answer still in flight is kept too, so a request made
  // meanwhile waits on it instead of asking again. Bounded, oldest out first:
  // every frame of every open tab keeps one.
  var verdicts = new Map(); // url -> false | true | 'data:...' | a Promise of one
  var MAX_VERDICTS = 500;
  function remember(url, verdict) {
    verdicts.delete(url);
    verdicts.set(url, verdict);
    if (verdicts.size > MAX_VERDICTS) verdicts.delete(verdicts.keys().next().value);
  }

  function ask(url) {
    if (!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler)) {
      return false;
    }
    var answer = window.flutter_inappwebview.callHandler('blockCheck', url).then(function(d) {
      // A redirect stays a URL: coercing it to a bool would drop the request
      // the rule meant to serve a stub to (CB-010).
      var verdict = isRedirect(d) ? d : !!d;
      remember(url, verdict);
      return verdict;
    }, function(e) {
      if (verdicts.get(url) === answer) verdicts.delete(url);
      throw e;
    });
    remember(url, answer);
    return answer;
  }

  // The verdict on url when it is known now: false (allow), true (block) or a
  // `data:` URL to load instead. Otherwise a promise of it, from Dart. Only
  // the Bloom filters' "maybe" is ever asked: a miss is a sure allow.
  function verdictFor(url) {
    if (!url || typeof url !== 'string' || url.charCodeAt(0) !== 104) return false; // 'h'
    if (url.indexOf('http') !== 0) return false;
    var host;
    try { host = new URL(url).hostname; } catch (e) { return false; }
    if (!host) return false;
    var known = verdicts.get(url);
    if (known !== undefined) return known;
    if (bloomReady && !maybeBlocked(host) &&
        !(hasGeneric && (genericFallback || urlMaybeGeneric(url)))) {
      return false;
    }
    return ask(url);
  }

  // Runs act with the verdict on url, in this task when it is known, so the
  // common case adds no microtask; otherwise once Dart answers.
  function whenDecided(url, act) {
    var v = verdictFor(url);
    return v !== null && typeof v === 'object' ? v.then(act) : act(v);
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
      // The response carries no host list. The app-wide domain-decision
      // cache used to be seeded in here as a warm start, but any page can
      // call this handler and there is no origin allowlist — that made
      // every other site's browsing history readable from page JS. The
      // bloom answers the same question; a cold verdict cache only costs a
      // Dart round-trip on the first bloom hit per URL.
      bloomReady = true;
    });
  }
  loadBloom();

  // Decision encoding (returned by callHandler('blockCheck')):
  //   false       — allow
  //   true        — block (drop)
  //   <string>    — block + redirect; string is a `data:` URL to
  //                 swap the request with. Engine's $redirect= path.
  // The Bloom prefilter only knows host membership, not redirect
  // specifics, so a redirect is only ever learnt from Dart.
  function isRedirect(d) { return typeof d === 'string' && d.indexOf('data:') === 0; }

  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function(input, init) {
      var url = typeof input === 'string' ? input : (input && input.url);
      var self = this;
      return whenDecided(url, function(verdict) {
        if (isRedirect(verdict)) return origFetch.call(self, verdict, init);
        if (verdict) return Promise.reject(new TypeError('Blocked: ' + url));
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
  // A known verdict sends synchronously, which a synchronous XHR needs.
  XMLHttpRequest.prototype.send = function(body) {
    var self = this;
    var args = arguments;
    whenDecided(this.__dnsBlockUrl, function(verdict) {
      if (verdict) { try { self.abort(); } catch (e) {} return; }
      origSend.apply(self, args);
    });
  };

  // Property setters for src/href. CRITICAL that a known verdict is
  // applied synchronously: wrapping `el.src = url` in
  // `Promise.resolve().then(set)` delays every image load by one
  // microtask. On a typical e-commerce page with 200 product images
  // that's 200 microtasks — visible jitter and dropped scroll frames.
  function patchSetter(proto, attr) {
    var desc = Object.getOwnPropertyDescriptor(proto, attr);
    if (!desc || !desc.set) return;
    var origSet = desc.set;
    Object.defineProperty(proto, attr, {
      configurable: true,
      enumerable: desc.enumerable,
      get: desc.get,
      set: function(value) {
        var el = this;
        whenDecided(value, function(verdict) {
          if (isRedirect(verdict)) origSet.call(el, verdict);
          else if (!verdict) origSet.call(el, value);
        });
      }
    });
  }
  patchSetter(HTMLImageElement.prototype, 'src');
  patchSetter(HTMLScriptElement.prototype, 'src');
  patchSetter(HTMLLinkElement.prototype, 'href');
  patchSetter(HTMLIFrameElement.prototype, 'src');

  // MutationObserver for statically-parsed HTML elements. An allowed
  // element keeps its attribute; only blocked elements are stripped (or
  // rewritten when the engine offers a redirect body).
  function checkElement(el) {
    var attr = null;
    if (el.tagName === 'IMG' || el.tagName === 'SCRIPT' || el.tagName === 'IFRAME') attr = 'src';
    else if (el.tagName === 'LINK') attr = 'href';
    if (!attr) return;
    var url = el.getAttribute(attr);
    if (!url || url.indexOf('http') !== 0) return;
    whenDecided(url, function(verdict) {
      if (isRedirect(verdict)) {
        el.setAttribute(attr, verdict);
        return;
      }
      if (verdict) {
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
