import 'package:webspace/settings/user_script.dart';

/// JavaScript shim that intercepts <script> DOM insertions and provides
/// a CORS-bypassing fetch function for user scripts.
///
/// Three interceptions:
/// 1. `<script src="...">` for whitelisted CDN URLs — Dart fetches the URL
///    and injects the body via evaluateJavascript (bypassing page CSP).
/// 2. `<script>` with inline textContent (no `src`) — Dart receives the
///    source and runs it via evaluateJavascript (bypassing page CSP).
///    Required for libraries like DarkReader whose `injectProxy` does
///    `head.append(scriptEl)` with inline text; Chromium WebView enforces
///    CSP strictly on this pattern, WKWebView is more lenient.
/// 3. `window.__wsFetch(url)` — CORS-bypassing fetch returning a Response.
///
/// Wrapped DOM entry points: `Node.prototype.appendChild`,
/// `Node.prototype.insertBefore`, `Element.prototype.append`. DarkReader
/// uses `append()` (not `appendChild`), so the `Element.append` wrapper
/// is what unblocks it on Android.
///
/// Lives in its own file (no Flutter imports) so the fixture dumper at
/// `tool/dump_shim_js.dart` can call [buildUserScriptShim] under
/// `fvm dart run` without pulling in the Flutter framework.
///
/// Security:
/// - Shim only installed on sites with user scripts enabled. The user has
///   opted into running custom JS; bypassing CSP for inline scripts on
///   that one site is in scope.
/// - Handler names are randomized per webview instance (placeholders
///   replaced at runtime) so page code cannot guess or call them.
/// - callHandler reference is captured lazily on first use.
/// - For `<script src>`, only whitelisted CDN URLs are intercepted; other
///   URLs fall through to normal (CSP-governed) DOM behavior.
const String userScriptShimTemplate = r'''
(function() {
  if (window.__wsFetchShimInstalled) return;
  window.__wsFetchShimInstalled = true;
  var _origAppend = Node.prototype.appendChild;
  var _origInsert = Node.prototype.insertBefore;
  var _origElemAppend = Element.prototype.append;
  var SCRIPT_HANDLER = '__SCRIPT_HANDLER_NAME__';
  var FETCH_HANDLER = '__FETCH_HANDLER_NAME__';
  var INLINE_SCRIPT_HANDLER = '__INLINE_SCRIPT_HANDLER_NAME__';

  // Lazily capture the bridge reference. At DOCUMENT_START the
  // flutter_inappwebview bridge may not be injected yet. By the time
  // user scripts actually call appendChild or __wsFetch (after the
  // library <script> loads), the bridge will be available.
  var _call = null;
  function call() {
    if (!_call) {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        _call = window.flutter_inappwebview.callHandler.bind(window.flutter_inappwebview);
      }
    }
    if (!_call) return null;
    return _call.apply(null, arguments);
  }

  var WHITELIST = __WHITELIST_JSON__;

  function isFetchableUrl(url) {
    if (typeof url !== 'string' || url.length === 0) return false;
    var lower = url.toLowerCase();
    return lower.indexOf('http://') === 0 || lower.indexOf('https://') === 0;
  }

  function isWhitelistedUrl(url) {
    if (!isFetchableUrl(url)) return false;
    try {
      var host = new URL(url).hostname.toLowerCase();
      for (var i = 0; i < WHITELIST.length; i++) {
        if (host === WHITELIST[i] || host.endsWith('.' + WHITELIST[i])) return true;
      }
    } catch(e) {}
    return false;
  }

  // Track URLs already fetched + injected to avoid double-loading
  // when initialUserScripts and onLoadStop both run the same script.
  var _loadedUrls = {};

  function intercept(scriptEl) {
    var url = scriptEl.src;
    // Only intercept whitelisted CDN URLs. Site scripts (e.g.,
    // platform.linkedin.com) fall through to normal DOM behavior.
    if (!isWhitelistedUrl(url)) return null;
    // If already loaded, just fire onload without re-fetching.
    if (_loadedUrls[url]) {
      var onload = scriptEl.onload;
      if (onload) setTimeout(function() { try { onload.call(scriptEl); } catch(e) { console.error('__ws: dedup onload error:', e); } }, 0);
      return scriptEl;
    }
    var result = call(SCRIPT_HANDLER, url);
    if (!result) return null;
    var onload = scriptEl.onload;
    var onerror = scriptEl.onerror;
    result.then(function(ok) {
      if (ok) {
        _loadedUrls[url] = true;
        if (onload) try { onload.call(scriptEl); } catch(e) { console.error('__ws: onload error:', e); }
      }
      else { if (onerror) try { onerror.call(scriptEl, new Error('fetch failed')); } catch(e) { console.error('__ws: onerror error:', e); } }
    }).catch(function(e) {
      if (onerror) try { onerror.call(scriptEl, e); } catch(e2) {}
    });
    return scriptEl;
  }

  // Catch inline <script>{textContent} elements and route them through
  // the privileged Dart bridge so they bypass the page's strict CSP.
  // Returns the element (un-appended) on success, null to fall through.
  function interceptInline(scriptEl) {
    if (scriptEl.src) return null;
    var inlineSource = scriptEl.text || scriptEl.textContent || '';
    if (typeof inlineSource !== 'string' || inlineSource.length === 0) return null;
    var result = call(INLINE_SCRIPT_HANDLER, inlineSource);
    if (!result) return null;
    return scriptEl;
  }

  function interceptScript(scriptEl) {
    if (!(scriptEl instanceof HTMLScriptElement)) return null;
    if (scriptEl.src) return intercept(scriptEl);
    return interceptInline(scriptEl);
  }

  Node.prototype.appendChild = function(child) {
    var result = interceptScript(child);
    if (result) return result;
    return _origAppend.call(this, child);
  };
  Node.prototype.insertBefore = function(child, ref) {
    var result = interceptScript(child);
    if (result) return result;
    return _origInsert.call(this, child, ref);
  };
  // Element.prototype.append accepts variadic Node|string args and does
  // NOT call Node.prototype.appendChild internally — it's a separate path
  // in the DOM impl. DarkReader's injectProxy uses
  // `(document.head||document.documentElement).append(proxyScript)`, so
  // without wrapping append() too, the inline-script intercept above
  // never fires for DarkReader's pattern.
  Element.prototype.append = function() {
    var passthrough = [];
    for (var i = 0; i < arguments.length; i++) {
      var n = arguments[i];
      if (interceptScript(n)) continue;
      passthrough.push(n);
    }
    if (passthrough.length === 0) return undefined;
    return _origElemAppend.apply(this, passthrough);
  };

  // CORS-bypassing fetch for user scripts. Returns a standard Response object.
  // Usage: myLibrary.setFetchMethod(window.__wsFetch);
  window.__wsFetch = function(url) {
    var urlStr = typeof url === 'string' ? url : url.toString();
    if (!isFetchableUrl(urlStr)) {
      return Promise.reject(new Error('__wsFetch: only http/https URLs supported'));
    }
    var result = call(FETCH_HANDLER, urlStr);
    if (!result) {
      console.log('__wsFetch: bridge not available for ' + urlStr.substring(0, 80));
      return Promise.reject(new Error('__wsFetch: bridge not available'));
    }
    return result.then(function(r) {
      console.log('__wsFetch: ' + urlStr.substring(0, 60) + ' -> status=' + (r && r.status) + ' body=' + (r && r.body ? r.body.length + 'b' : 'none'));
      if (r && r.body !== undefined) {
        return new Response(r.body, {
          status: r.status || 200,
          headers: r.contentType ? { 'Content-Type': r.contentType } : {},
        });
      }
      return new Response('', { status: 500 });
    });
  };

  // WKWebView (iOS) has been observed to resolve `FileReader` to nothing in
  // the page context ("ReferenceError: Can't find variable: FileReader"),
  // breaking libraries that convert fetched blobs to data URLs — DarkReader's
  // readResponseAsDataURL does `new FileReader()` for every image it inlines.
  // Minimal async polyfill over Blob.arrayBuffer()/text(); only installed
  // when the native constructor is absent.
  if (typeof window.FileReader === 'undefined') {
    (function() {
      function WSFileReader() {
        this.result = null;
        this.error = null;
        this.readyState = 0;
        this.onload = null;
        this.onloadend = null;
        this.onerror = null;
      }
      WSFileReader.EMPTY = 0;
      WSFileReader.LOADING = 1;
      WSFileReader.DONE = 2;
      function finish(reader, result, error) {
        reader.readyState = 2;
        reader.result = result;
        reader.error = error || null;
        var evt = { target: reader, type: error ? 'error' : 'load' };
        try {
          if (error) { if (reader.onerror) reader.onerror(evt); }
          else if (reader.onload) reader.onload(evt);
        } catch (e) {}
        try { if (reader.onloadend) reader.onloadend({ target: reader, type: 'loadend' }); } catch (e) {}
      }
      function toBase64(buf) {
        var bytes = new Uint8Array(buf);
        var bin = '';
        for (var i = 0; i < bytes.length; i += 0x8000) {
          bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(bin);
      }
      WSFileReader.prototype.readAsArrayBuffer = function(blob) {
        var self = this;
        this.readyState = 1;
        blob.arrayBuffer().then(function(buf) { finish(self, buf); }, function(e) { finish(self, null, e); });
      };
      WSFileReader.prototype.readAsText = function(blob) {
        var self = this;
        this.readyState = 1;
        blob.text().then(function(t) { finish(self, t); }, function(e) { finish(self, null, e); });
      };
      WSFileReader.prototype.readAsDataURL = function(blob) {
        var self = this;
        this.readyState = 1;
        blob.arrayBuffer().then(function(buf) {
          finish(self, 'data:' + (blob.type || 'application/octet-stream') + ';base64,' + toBase64(buf));
        }, function(e) { finish(self, null, e); });
      };
      WSFileReader.prototype.abort = function() {};
      WSFileReader.prototype.addEventListener = function(type, fn) { this['on' + type] = fn; };
      WSFileReader.prototype.removeEventListener = function(type, fn) { if (this['on' + type] === fn) this['on' + type] = null; };
      window.FileReader = WSFileReader;
    })();
  }

  // Patch window.fetch to fall back to __wsFetch on CORS errors.
  // Only catches TypeError (which browsers throw for CORS and network
  // failures), not application errors like 404. This avoids breaking
  // video/binary fetches that fail for non-CORS reasons.
  //
  // Scoped to cross-SITE URLs (different registrable domain), not merely
  // cross-origin. __wsFetch reissues the request through the Dart bridge,
  // which carries none of the WebView's cookies or request headers, so
  // retrying a session-bound request there makes the site see an
  // unauthenticated client — a logged-in site starts demanding login.
  // Cookies scope to the registrable domain, so a same-site subdomain
  // (www.linkedin.com -> realtime.www.linkedin.com) is just as
  // session-bound as a same-origin URL; both must rethrow untouched.
  // The registrable-domain heuristic is last-two-labels: under multi-part
  // public suffixes (co.uk) it over-approximates "same site", which only
  // disables the fallback — the safe direction.
  //
  // Also restricted to bodyless (GET/HEAD), non-credentialed requests:
  // __wsFetch always issues a GET without the original init, so retrying a
  // POST would silently convert it, and credentials:'include' explicitly
  // marks the request session-bound regardless of site.
  function baseDomain(host) {
    var parts = host.toLowerCase().split('.');
    return parts.length <= 2 ? host.toLowerCase() : parts.slice(-2).join('.');
  }
  function isCrossSite(u) {
    try {
      return baseDomain(new URL(u, location.href).hostname) !== baseDomain(location.hostname);
    } catch (e) { return false; }
  }
  var _origFetch = window.fetch.bind(window);
  window.fetch = function(input, init) {
    return _origFetch(input, init).catch(function(err) {
      if (err instanceof TypeError) {
        var isReq = input && typeof input === 'object';
        var url = typeof input === 'string' ? input : (isReq && input.url ? input.url : '');
        var method = ((init && init.method) || (isReq && input.method) || 'GET').toUpperCase();
        var credentials = (init && init.credentials) || (isReq && input.credentials) || '';
        if (isFetchableUrl(url) && isCrossSite(url)
            && (method === 'GET' || method === 'HEAD')
            && credentials !== 'include') {
          return window.__wsFetch(url);
        }
      }
      throw err;
    });
  };
})();
''';

/// Build the user-script shim with explicit handler names. Production code
/// uses [UserScriptService] which generates randomized names per webview
/// instance; the fixture dumper (`tool/dump_shim_js.dart`) calls this
/// directly with deterministic names so the on-disk fixture under
/// `test/js_fixtures/user_script/` stays stable across runs.
String buildUserScriptShim({
  required String scriptHandlerName,
  required String fetchHandlerName,
  required String inlineScriptHandlerName,
}) {
  final whitelistJson = '[${scriptFetchWhitelist.map((d) => '"$d"').join(',')}]';
  return userScriptShimTemplate
      .replaceAll('__SCRIPT_HANDLER_NAME__', scriptHandlerName)
      .replaceAll('__FETCH_HANDLER_NAME__', fetchHandlerName)
      .replaceAll('__INLINE_SCRIPT_HANDLER_NAME__', inlineScriptHandlerName)
      .replaceAll('__WHITELIST_JSON__', whitelistJson);
}
