// Worker / SharedWorker shim propagation.
//
// Every per-site JS shim (language, UA identity, timezone, anti-fingerprinting)
// is injected as a `UserScript` into the *document*. A `Worker` or
// `SharedWorker` runs in a separate global scope that no UserScript reaches, so
// a page that re-reads the same values inside a worker sees the real OS/engine
// values instead of the spoofed ones. That is not a partial leak but a total
// bypass, and a deliberate one: CreepJS re-reads locale, timezone, UA, cores
// and GPU inside a worker precisely to defeat main-thread-only spoofing, then
// reports the page/worker disagreement as its strongest signal.
//
// Mechanism: patch the `Worker` / `SharedWorker` constructors so the script URL
// the page asked for is replaced by a generated `blob:` script that first loads
// the shim payload, then the original script:
//
//     importScripts(<shim blob>); importScripts(<original url>);
//
// Both loads are synchronous and ordered, so the shims are installed before a
// single line of the site's worker code runs — the worker-scope equivalent of
// `AT_DOCUMENT_START`. A blob worker inherits the creating document's origin,
// and classic worker scripts are same-origin by spec, so `importScripts` of the
// original URL is always permitted.
//
// The payload is the SAME shim source the page gets, which is the point: a
// worker reporting a different `hardwareConcurrency` than its page would be a
// fresh fingerprint. The shims are scope-agnostic (`globalThis`, navigator
// prototype resolved from the live `navigator`, window-only sections guarded),
// so one source serves both scopes.
//
// Known limits, all fail-open (functionality preferred over an extra spoof):
//   * A CSP that forbids `blob:` workers makes worker creation fail. We cannot
//     detect that synchronously (the failure surfaces as an async `error`
//     event), so sites under such a CSP keep unspoofed workers.
//   * Module workers (`{type:'module'}`) get the shim via ordered static
//     `import`s, but no nested propagation (`import.meta` cannot appear in the
//     classic payload).
//   * Service workers are out of reach: registration rejects `blob:` scripts.

import 'dart:convert';

/// Compose the page-side installer that patches `Worker` / `SharedWorker` to
/// preload [shimSources] into every worker global scope.
///
/// [shimSources] are the same shim bodies injected into the document, in
/// injection order. Returns `null` when there is nothing to propagate, so a
/// site with no active spoofing keeps the stock constructors (and therefore
/// cannot be broken by the blob indirection).
String? buildWorkerShimScript(List<String> shimSources) {
  final active = shimSources
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (active.isEmpty) return null;

  // The payload runs in worker scope. Its tail re-installs the same patch
  // inside the worker so a worker spawning a worker stays covered; it reads its
  // own blob URL from `__wsShimUrl`, which the generated wrapper assigns before
  // importing it (a script cannot otherwise learn the URL it was loaded from).
  final payload = '''
${active.join('\n')}
$_installerDefinition
(function() {
  try {
    var u = globalThis.__wsShimUrl;
    try { delete globalThis.__wsShimUrl; } catch (e) {}
    if (u) __wsInstallWorkerWrap(function() { return u; });
  } catch (e) {}
})();
''';

  final encodedPayload = jsonEncode(payload);

  return '''
(function() {
  'use strict';
$_installerDefinition
  var PAYLOAD = $encodedPayload;
  var _url = null;
  __wsInstallWorkerWrap(function() {
    if (_url === null) {
      _url = URL.createObjectURL(new Blob([PAYLOAD], { type: 'text/javascript' }));
    }
    return _url;
  });
})();
''';
}

/// JS defining `__wsInstallWorkerWrap(getShimUrl)`, shared verbatim by the
/// page-side installer and the payload's nested-worker tail. `getShimUrl` is
/// the only thing that differs between the two (the page builds the blob from
/// the embedded payload; a worker reuses the URL it was loaded from).
const String _installerDefinition = r'''
  function __wsInstallWorkerWrap(getShimUrl) {
    if (globalThis.__ws_worker_shim__) return;
    globalThis.__ws_worker_shim__ = true;

    var _origFnToString = Function.prototype.toString;
    var _stubs = globalThis.__wsFnStubs || new WeakMap();
    globalThis.__wsFnStubs = _stubs;
    function asNative(fn, name) {
      try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}
      return fn;
    }
    // Patch toString here rather than leaning on a sibling shim having done it:
    // the patched constructors are the most obvious thing a fingerprinter
    // stringifies, and this installer must not depend on injection order.
    if (!globalThis.__wsFnToStringPatched) {
      globalThis.__wsFnToStringPatched = true;
      var patched = function toString() {
        var stub = _stubs.get(this);
        return stub !== undefined ? stub : _origFnToString.call(this);
      };
      try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}
      try { Function.prototype.toString = patched; } catch (e) {}
    }

    // Cache wrapped URLs per (script, type). SharedWorker identity is keyed on
    // the script URL, so handing out a fresh blob per call would turn one
    // shared worker into N unshared ones and break the page.
    var _wrapped = new Map();

    function wrap(script, isModule) {
      var abs = new URL(String(script), globalThis.location.href).href;
      var key = (isModule ? 'm:' : 'c:') + abs;
      var hit = _wrapped.get(key);
      if (hit) return hit;
      var shimUrl = getShimUrl();
      if (!shimUrl) return null;
      var body;
      if (isModule) {
        // Static imports evaluate in source order, so the shim is fully applied
        // before the original module body runs. Dynamic import() would resolve
        // in a later task and could lose messages posted meanwhile.
        body = 'import ' + JSON.stringify(shimUrl) + ';\n' +
               'import ' + JSON.stringify(abs) + ';\n';
      } else {
        body = 'self.__wsShimUrl = ' + JSON.stringify(shimUrl) + ';\n' +
               'importScripts(' + JSON.stringify(shimUrl) + ');\n' +
               'importScripts(' + JSON.stringify(abs) + ');\n';
      }
      var url = URL.createObjectURL(new Blob([body], { type: 'text/javascript' }));
      _wrapped.set(key, url);
      return url;
    }

    function patch(name) {
      var Real = globalThis[name];
      if (typeof Real !== 'function') return;
      var Patched = function (script, options) {
        try {
          var isModule = !!(options && options.type === 'module');
          var url = wrap(script, isModule);
          if (url) return new Real(url, options);
        } catch (e) {}
        // Fail open: a broken worker is worse than an unspoofed one.
        return new Real(script, options);
      };
      try { Patched.prototype = Real.prototype; } catch (e) {}
      try {
        Object.defineProperty(Patched, 'name', { value: name, configurable: true });
      } catch (e) {}
      asNative(Patched, name);
      try { globalThis[name] = Patched; } catch (e) {}
    }

    patch('Worker');
    patch('SharedWorker');
  }
''';
