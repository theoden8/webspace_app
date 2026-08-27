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
// A CSP whose `worker-src` omits `blob:` refuses the wrapper, and chromium
// reports that refusal as an asynchronous `error` event on the worker rather
// than a constructor throw — so the fail-open branch below never sees it and
// the site is left with a worker that never starts (messenger.com: the chat
// worker dies and "verifying your PIN" hangs forever). There is no synchronous
// way to ask a CSP about `blob:` worker scripts, so the installer asks the
// engine instead: it starts one throwaway blob worker at document start and
// remembers the answer. Once a refusal is known, wrapping stops and workers
// are handed their original script — unshimmed, but alive.
//
// Known limits, all fail-open (functionality preferred over an extra spoof):
//   * Under such a CSP the workers run unshimmed, which is a live page/worker
//     disagreement (WORK-002) — the trade WORK-006 makes, and the reason the
//     probe exists rather than a blanket bypass.
//   * A worker created before the probe's answer arrives (an inline script at
//     the top of the document) still gets the doomed wrapper.
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
    if (u) __wsInstallWorkerWrap(function() { return u; }, false);
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
  }, true);
})();
''';
}

/// JS defining `__wsInstallWorkerWrap(getShimUrl, watchCsp)`, shared verbatim
/// by the page-side installer and the payload's nested-worker tail.
/// `getShimUrl` is what differs between the two (the page builds the blob from
/// the embedded payload; a worker reuses the URL it was loaded from), and
/// `watchCsp` is page-only: a worker running the payload is itself proof that
/// this document's CSP admits `blob:` workers, so it has nothing to probe.
const String _installerDefinition = r'''
  function __wsInstallWorkerWrap(getShimUrl, watchCsp) {
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

    // Whether this document's CSP admits a `blob:` worker script at all.
    // Refused means every wrapper is dead on arrival, and because the refusal
    // is asynchronous the constructor below cannot fail open on it — so it is
    // recorded here instead and read before wrapping anything else.
    var _blobRefused = false;
    var _blobProven = false;

    // Starts one throwaway worker: a message back proves `blob:` workers run
    // here, an error proves the CSP refuses them. Runs at document start so
    // the answer is in before the site builds a worker of its own.
    function probeBlobWorkers() {
      var Real = globalThis.Worker;
      if (typeof Real !== 'function') return;
      try {
        var url = URL.createObjectURL(new Blob(
          ['postMessage(1);close();'], { type: 'text/javascript' }));
        var probe = new Real(url);
        var finish = function (refused) {
          if (refused && !_blobProven) _blobRefused = true;
          if (!refused) _blobProven = true;
          try { probe.terminate(); } catch (e) {}
          // Only ever after the load settled: revoking while the script is
          // still in flight would fail the probe on a page that was fine.
          try { URL.revokeObjectURL(url); } catch (e) {}
        };
        probe.onmessage = function () { finish(false); };
        probe.onerror = function (e) {
          try { e.preventDefault(); } catch (e2) {}
          finish(true);
        };
      } catch (e) {
        _blobRefused = true;
      }
    }

    // Covers the window before the probe answers, and the directives it does
    // not exercise: a refused `blob:` under anything that governs worker
    // scripts says what the probe would have said. Ignored once the probe has
    // seen a blob worker run, so a site that blocks blob *scripts* while
    // allowing blob *workers* keeps its workers shimmed.
    function watchBlobRefusals() {
      if (typeof document === 'undefined' || !document.addEventListener) return;
      document.addEventListener('securitypolicyviolation', function (e) {
        var blocked = String(e.blockedURI || '');
        if (blocked !== 'blob' && blocked.indexOf('blob:') !== 0) return;
        var directive = String(e.effectiveDirective || e.violatedDirective || '');
        if (/^(worker|child|script|default)-src/.test(directive) && !_blobProven) {
          _blobRefused = true;
        }
      }, true);
    }

    function wrap(script, isModule) {
      // Null hands the page's own script to the real constructor: unshimmed,
      // but a worker that starts (WORK-006).
      if (_blobRefused) return null;
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
        //
        // `__wsShimUrl` has to arrive via its own imported module: an
        // assignment in this body would run *after* both imports (module
        // evaluation is hoisted), so the shim's tail would find nothing and
        // skip re-installing the Worker patch — leaving anything this module
        // worker spawns unshimmed.
        var setter = URL.createObjectURL(new Blob(
          ['globalThis.__wsShimUrl = ' + JSON.stringify(shimUrl) + ';\n'],
          { type: 'text/javascript' }));
        body = 'import ' + JSON.stringify(setter) + ';\n' +
               'import ' + JSON.stringify(shimUrl) + ';\n' +
               'import ' + JSON.stringify(abs) + ';\n';
      } else {
        // The shim import is caught, the original's is not: a CSP that
        // admits blob: workers but not blob: scripts must cost the spoof,
        // never the site's worker. The handle goes with it, so a scope the
        // payload never reached is not left with an own-property to find.
        body = 'self.__wsShimUrl = ' + JSON.stringify(shimUrl) + ';\n' +
               'try { importScripts(' + JSON.stringify(shimUrl) + '); }\n' +
               'catch (e) { try { delete self.__wsShimUrl; } catch (e2) {} }\n' +
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

    if (watchCsp) {
      watchBlobRefusals();
      probeBlobWorkers();
    }

    patch('Worker');
    patch('SharedWorker');
  }
''';
