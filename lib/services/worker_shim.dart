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
// worker dies and "verifying your PIN" hangs forever).
//
// A page cannot read the policy that would say so in advance. A header-
// delivered CSP is invisible to JS, and the one time the platform hands a page
// its own policy is inside a violation report — from in here, the only way to
// learn the rule is to break it. So nothing is asked in advance: the site's
// first worker is the test. It gets a wrapper, and if the CSP refuses it the
// worker is rebuilt on the site's own script behind the object the page
// already holds, which the page cannot tell apart from the worker it asked
// for. That refusal is the answer, and every worker after it is handed its
// original script — unshimmed, but alive.
//
// So a document that never builds a worker never touches the CSP, where asking
// up front announced the app to every site on every load. When the site
// happens to break its own policy first for unrelated reasons, the report
// carries `originalPolicy` and the same answer is read out of it for free.
//
// Known limits, all fail-open (functionality preferred over an extra spoof):
//   * Under such a CSP the workers run unshimmed, which is a live page/worker
//     disagreement (WORK-002) — the trade WORK-006 makes rather than leaving
//     the site with workers that do not start.
//   * The first worker of a refusing document is the one that pays for the
//     answer: it is rebuilt, so it runs, but it costs one CSP violation.
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
    //
    // A worker running the payload is itself proof that its document admits
    // them, which is why the nested install starts answered.
    var _blobRefused = false;
    var _blobProven = !watchCsp;

    // Wrappers handed out before the answer is known. A wrapper the CSP
    // refuses fails asynchronously, long after its constructor returned, so
    // the fail-open branch cannot see it and the page is left holding a worker
    // that never starts. Each entry rebuilds one of those on the site's own
    // script, or drops its bookkeeping once blob: workers are known to run.
    var _pending = [];
    function settle(refused) {
      var armed = _pending;
      _pending = [];
      for (var i = 0; i < armed.length; i++) {
        try { armed[i](refused); } catch (e) {}
      }
    }
    function markRefused() {
      if (_blobRefused || _blobProven) return;
      _blobRefused = true;
      settle(true);
    }
    function markProven() {
      if (_blobProven) return;
      _blobProven = true;
      settle(false);
    }

    // Shared by both rescues: shadow one of [w]'s own methods with [fn],
    // stringifying as the native one it stands in for.
    function own(w, name, fn) {
      try {
        Object.defineProperty(w, name, {
          value: asNative(fn, name), writable: true, configurable: true });
      } catch (e) {}
    }
    // Registered before the page can hold the worker, so stopping the event
    // here stops the page's handlers with it.
    function swallow(ev) {
      try { ev.preventDefault(); } catch (e) {}
      try { ev.stopImmediatePropagation(); } catch (e) {}
    }
    // The page's messages are recorded rather than withheld: holding them
    // until the answer arrives would delay every worker on every site to buy
    // the refused one. The cap bounds a worker that is never answered for at
    // all, since a refusal always lands within a task or two of construction.
    var RECORD_LIMIT = 32;

    // Keeps [w] — the object the page already holds — usable whichever way the
    // answer goes, by swapping a worker built on the site's own script in
    // behind it. The page's handlers, its `instanceof`, and every reference it
    // handed out survive, which re-issuing the constructor could not do.
    function armRescue(Real, w, script, options) {
      var post, term;
      try {
        post = w.postMessage;
        term = w.terminate;
        if (typeof post !== 'function' || typeof term !== 'function' ||
            typeof w.addEventListener !== 'function') return;
      } catch (e) { return; }

      // 'waiting' until the answer lands, then 'kept' (blob: workers run here,
      // or the page terminated this one) or 'swapped' (rebuilt behind [w]).
      var state = 'waiting';
      // The rebuilt worker once there is one. Everything [w] exposes reads it,
      // so a reference the page took while waiting keeps working after a swap.
      var real = null;
      var sent = [];
      var relaying = false;

      own(w, 'postMessage', function () {
        if (real) return real.postMessage.apply(real, arguments);
        if (sent && sent.length < RECORD_LIMIT) {
          sent.push(Array.prototype.slice.call(arguments));
        }
        return post.apply(w, arguments);
      });
      own(w, 'terminate', function () {
        if (real) return real.terminate();
        keep();
        return term.call(w);
      });

      // A refused wrapper never reaches any script, so its error carries no
      // message; an error thrown by the site's own worker code does, and is
      // the page's to see. Unhooked once blob: workers are known to run, where
      // a message-less error means the site's own script failed to load and
      // the page must hear about it.
      function onError(ev) {
        if (relaying || ev.message) return;
        swallow(ev);
        // After a swap this is the refused wrapper's own error, arriving late
        // for a worker the page never got to use.
        if (state === 'waiting') markRefused();
      }
      // Anything this worker says is proof that its wrapper ran, which is the
      // answer the document needed and the end of every arm on the page.
      function onMessage() { if (!relaying) markProven(); }
      try {
        w.addEventListener('error', onError, true);
        w.addEventListener('message', onMessage, true);
      } catch (e) {}

      function keep() {
        state = 'kept';
        sent = null;
        try { delete w.postMessage; } catch (e) {}
        try { delete w.terminate; } catch (e) {}
        try { w.removeEventListener('error', onError, true); } catch (e) {}
        try { w.removeEventListener('message', onMessage, true); } catch (e) {}
      }
      // Re-dispatched on [w] so the page's own handlers see it, and flagged
      // while in flight so the listeners above do not read one back as the
      // wrapper answering or failing.
      function relay(type, e) {
        relaying = true;
        try {
          w.dispatchEvent(type === 'error'
            ? new ErrorEvent('error', { message: e.message,
                filename: e.filename, lineno: e.lineno, colno: e.colno })
            : new MessageEvent(type, { data: e.data, ports: e.ports }));
        } catch (e2) {} finally { relaying = false; }
      }
      function swap() {
        var built;
        try { built = new Real(script, options); } catch (e) { keep(); return; }
        state = 'swapped';
        real = built;
        built.onmessage = function (e) { relay('message', e); };
        built.onmessageerror = function (e) { relay('messageerror', e); };
        built.onerror = function (e) {
          try { e.preventDefault(); } catch (e2) {}
          relay('error', e);
        };
        try { term.call(w); } catch (e) {}
        var queued = sent || [];
        sent = null;
        for (var i = 0; i < queued.length; i++) {
          try { built.postMessage.apply(built, queued[i]); } catch (e) {}
        }
      }

      _pending.push(function (refused) {
        if (state !== 'waiting') return;
        if (refused) swap(); else keep();
      });
    }

    // The same trade for a `SharedWorker`, which cannot be swapped the same
    // way: the page takes its `MessagePort` at construction and a port cannot
    // be re-entangled with a second worker. So the page is handed one end of a
    // channel of ours instead, and the other end is what moves.
    function armSharedRescue(Real, w, script, options) {
      var mine, theirs, target;
      try {
        if (typeof MessageChannel !== 'function') return;
        target = w.port;
        if (!target || typeof w.addEventListener !== 'function') return;
        var chan = new MessageChannel();
        theirs = chan.port1;
        mine = chan.port2;
        Object.defineProperty(w, 'port', {
          value: theirs, writable: true, configurable: true });
      } catch (e) { return; }

      var state = 'waiting';
      var sent = [];
      var relaying = false;

      // Ports ride along: a MessagePort cannot be cloned, so forwarding a
      // message that carries one without its transfer list would throw and
      // lose it. Buffers are copied rather than transferred, which costs a
      // copy and breaks nothing.
      function listen(port) {
        port.onmessage = function (e) {
          if (state === 'waiting') markProven();
          try { mine.postMessage(e.data, e.ports || []); } catch (e2) {}
        };
        try { port.start(); } catch (e) {}
      }
      mine.onmessage = function (e) {
        var ports = e.ports || [];
        if (sent && sent.length < RECORD_LIMIT) sent.push([e.data, ports]);
        try { target.postMessage(e.data, ports); } catch (e2) {}
      };
      try { mine.start(); } catch (e) {}
      listen(target);

      function onError(ev) {
        if (relaying || ev.message) return;
        swallow(ev);
        if (state === 'waiting') markRefused();
      }
      try { w.addEventListener('error', onError, true); } catch (e) {}

      _pending.push(function (refused) {
        if (state !== 'waiting') return;
        if (!refused) {
          state = 'kept';
          sent = null;
          try { w.removeEventListener('error', onError, true); } catch (e) {}
          return;
        }
        var built;
        try { built = new Real(script, options); } catch (e) { return; }
        state = 'swapped';
        // The page holds [w], so the rebuilt worker's failures have to arrive
        // there; the refused wrapper's own error keeps being swallowed above.
        built.onerror = function (e) {
          try { e.preventDefault(); } catch (e2) {}
          relaying = true;
          try {
            w.dispatchEvent(new ErrorEvent('error', { message: e.message,
              filename: e.filename, lineno: e.lineno, colno: e.colno }));
          } catch (e2) {} finally { relaying = false; }
        };
        target = built.port;
        listen(target);
        var queued = sent || [];
        sent = null;
        for (var i = 0; i < queued.length; i++) {
          try { target.postMessage(queued[i][0], queued[i][1]); } catch (e) {}
        }
      });
    }

    // The one time the platform hands a page its own policy is inside a
    // violation report, whichever rule was broken, so read it there rather
    // than inferring an answer from the refusal in front of us. A report-only
    // policy blocks nothing and must not be read as a refusal.
    function watchCspViolations() {
      if (typeof document === 'undefined' || !document.addEventListener) return;
      document.addEventListener('securitypolicyviolation', function (e) {
        if (e.disposition && e.disposition !== 'enforce') return;
        var verdict = policyAdmitsBlobWorkers(String(e.originalPolicy || ''));
        if (verdict === true) { markProven(); return; }
        if (verdict === false) { markRefused(); return; }
        // No policy text on the event: fall back to what this refusal says on
        // its own. Only the directives that govern worker scripts count —
        // chromium names the effective one, so a policy that reaches workers
        // through `script-src` still reports `worker-src` here, and a refused
        // blob: *script* stays what it is.
        var blocked = String(e.blockedURI || '');
        if (blocked !== 'blob' && blocked.indexOf('blob:') !== 0) return;
        var directive = String(e.effectiveDirective || e.violatedDirective || '');
        if (/^(worker|child)-src/.test(directive)) markRefused();
      }, true);
    }

    // true / false / null when the policy says nothing about worker scripts.
    // Worker scripts fall back worker-src -> child-src -> script-src ->
    // default-src, and a `blob:` URL is admitted only by the scheme source
    // itself: neither `*` nor `'self'` covers it.
    function policyAdmitsBlobWorkers(policy) {
      if (!policy) return null;
      var answer = null;
      var policies = policy.split(',');
      for (var p = 0; p < policies.length; p++) {
        var directives = policies[p].split(';');
        var rank = -1;
        var sources = null;
        for (var i = 0; i < directives.length; i++) {
          var parts = directives[i].trim().split(/\s+/);
          var name = (parts[0] || '').toLowerCase();
          var r = name === 'worker-src' ? 3 : name === 'child-src' ? 2 :
                  name === 'script-src' ? 1 : name === 'default-src' ? 0 : -1;
          if (r > rank) { rank = r; sources = parts.slice(1); }
        }
        if (rank < 0) continue;
        var admits = false;
        for (var j = 0; j < sources.length; j++) {
          if (sources[j].toLowerCase() === 'blob:') { admits = true; break; }
        }
        // Every policy delivered has to admit it; one refusal is the answer.
        if (!admits) return false;
        answer = true;
      }
      return answer;
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
          if (url) {
            var w = new Real(url, options);
            // Nothing to rescue once blob: workers are known to run here.
            if (!_blobProven) {
              if (name === 'Worker') armRescue(Real, w, script, options);
              else armSharedRescue(Real, w, script, options);
            }
            return w;
          }
        } catch (e) {}
        // Fail open: a broken worker is worse than an unspoofed one.
        return new Real(script, options);
      };
      try { Patched.prototype = Real.prototype; } catch (e) {}
      // Re-point the inherited own `constructor`: otherwise
      // `Worker.prototype.constructor` is still the real constructor and a
      // worker built through it never loads the shim payload.
      try {
        Object.defineProperty(Patched.prototype, 'constructor',
          { value: Patched, writable: true, configurable: true });
      } catch (e) {}
      try {
        Object.defineProperty(Patched, 'name', { value: name, configurable: true });
      } catch (e) {}
      asNative(Patched, name);
      try { globalThis[name] = Patched; } catch (e) {}
    }

    if (watchCsp) watchCspViolations();

    patch('Worker');
    patch('SharedWorker');
  }
''';
