(function() {
  'use strict';
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

  var PAYLOAD = "(function() {\n  'use strict';\n  if (globalThis.__ws_language_shim__) return;\n  globalThis.__ws_language_shim__ = true;\n\n  var lang = \"en\";\n  var langs = Object.freeze([lang]);\n\n  // Shared Function.prototype.toString funnel (same WeakMap as the other\n  // shims) so every wrapper stringifies as `[native code]`.\n  var _origFnToString = Function.prototype.toString;\n  var _stubs = globalThis.__wsFnStubs || new WeakMap();\n  globalThis.__wsFnStubs = _stubs;\n  function asNative(fn, name) {\n    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}\n    return fn;\n  }\n  if (!globalThis.__wsFnToStringPatched) {\n    globalThis.__wsFnToStringPatched = true;\n    var patched = function toString() {\n      var stub = _stubs.get(this);\n      return stub !== undefined ? stub : _origFnToString.call(this);\n    };\n    try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}\n    try { Function.prototype.toString = patched; } catch (e) {}\n  }\n\n  // Resolved from the live `navigator` so this works unchanged in a worker,\n  // where the class is WorkerNavigator and `Navigator` does not exist.\n  var NavProto = (typeof navigator !== 'undefined' && navigator)\n    ? Object.getPrototypeOf(navigator) : null;\n\n  try {\n    if (NavProto) {\n      Object.defineProperty(NavProto, 'language', {\n        configurable: true, enumerable: true,\n        get: asNative(function language() { return lang; }, 'language'),\n      });\n      Object.defineProperty(NavProto, 'languages', {\n        configurable: true, enumerable: true,\n        get: asNative(function languages() { return langs; }, 'languages'),\n      });\n    }\n  } catch (e) {}\n\n  // True when the caller omitted the `locales` argument (or passed an empty\n  // list) — the only case in which a real engine falls back to the default\n  // locale, and thus the only case we override.\n  function localeOmitted(args) {\n    if (args.length === 0) return true;\n    var l = args[0];\n    return l === undefined || (Array.isArray(l) && l.length === 0);\n  }\n\n  // Wrap an Intl constructor so an omitted `locales` defaults to `lang`\n  // instead of the OS locale. Both `resolvedOptions().locale` and the\n  // formatted output then reflect the per-site tag. Delegates to whatever\n  // `Intl[name]` currently is, so it composes with the location shim's\n  // `Intl.DateTimeFormat` timezone wrapper regardless of injection order.\n  function wrapIntlCtor(name) {\n    try {\n      if (typeof Intl === 'undefined') return;\n      var Native = Intl[name];\n      if (typeof Native !== 'function') return;\n      function Wrapped() {\n        var args = localeOmitted(arguments)\n          ? [lang].concat(Array.prototype.slice.call(arguments, 1))\n          : arguments;\n        // Called without `new`: mirror the native behaviour exactly —\n        // DateTimeFormat/NumberFormat/Collator return an instance, the\n        // others throw. `Native.apply(null, ...)` reproduces both.\n        if (!(this instanceof Wrapped)) return Native.apply(null, args);\n        switch (args.length) {\n          case 0: return new Native();\n          case 1: return new Native(args[0]);\n          default: return new Native(args[0], args[1]);\n        }\n      }\n      Wrapped.prototype = Native.prototype;\n      // `Native.prototype.constructor` is an own property still pointing at\n      // `Native`, so without this `Intl[name].prototype.constructor` is an\n      // unwrapped constructor that resolves the OS locale.\n      try {\n        Object.defineProperty(Wrapped.prototype, 'constructor',\n          { value: Wrapped, writable: true, configurable: true });\n      } catch (e) {}\n      if (typeof Native.supportedLocalesOf === 'function') {\n        Wrapped.supportedLocalesOf = asNative(function supportedLocalesOf() {\n          return Native.supportedLocalesOf.apply(Native, arguments);\n        }, 'supportedLocalesOf');\n      }\n      asNative(Wrapped, name);\n      try { Intl[name] = Wrapped; } catch (e) {}\n    } catch (e) {}\n  }\n\n  [\n    'DateTimeFormat', 'NumberFormat', 'RelativeTimeFormat', 'DisplayNames',\n    'ListFormat', 'PluralRules', 'Collator', 'Segmenter',\n  ].forEach(wrapIntlCtor);\n\n  // Date/Number toLocale* fall back to the default locale when called with no\n  // (or `undefined`) first argument. Inject `lang` there too so a locale-less\n  // `date.toLocaleString()` matches the Intl output above.\n  function wrapLocaleMethod(proto, method) {\n    try {\n      if (!proto) return;\n      var orig = proto[method];\n      if (typeof orig !== 'function') return;\n      var wrapped = function () {\n        if (arguments.length === 0 || arguments[0] === undefined) {\n          return orig.call(this, lang, arguments[1]);\n        }\n        return orig.apply(this, arguments);\n      };\n      asNative(wrapped, method);\n      try { proto[method] = wrapped; } catch (e) {}\n    } catch (e) {}\n  }\n  wrapLocaleMethod(Date.prototype, 'toLocaleString');\n  wrapLocaleMethod(Date.prototype, 'toLocaleDateString');\n  wrapLocaleMethod(Date.prototype, 'toLocaleTimeString');\n  wrapLocaleMethod(Number.prototype, 'toLocaleString');\n})();\n  function __wsInstallWorkerWrap(getShimUrl, watchCsp) {\n    if (globalThis.__ws_worker_shim__) return;\n    globalThis.__ws_worker_shim__ = true;\n\n    var _origFnToString = Function.prototype.toString;\n    var _stubs = globalThis.__wsFnStubs || new WeakMap();\n    globalThis.__wsFnStubs = _stubs;\n    function asNative(fn, name) {\n      try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}\n      return fn;\n    }\n    // Patch toString here rather than leaning on a sibling shim having done it:\n    // the patched constructors are the most obvious thing a fingerprinter\n    // stringifies, and this installer must not depend on injection order.\n    if (!globalThis.__wsFnToStringPatched) {\n      globalThis.__wsFnToStringPatched = true;\n      var patched = function toString() {\n        var stub = _stubs.get(this);\n        return stub !== undefined ? stub : _origFnToString.call(this);\n      };\n      try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}\n      try { Function.prototype.toString = patched; } catch (e) {}\n    }\n\n    // Cache wrapped URLs per (script, type). SharedWorker identity is keyed on\n    // the script URL, so handing out a fresh blob per call would turn one\n    // shared worker into N unshared ones and break the page.\n    var _wrapped = new Map();\n\n    // Whether this document's CSP admits a `blob:` worker script at all.\n    // Refused means every wrapper is dead on arrival, and because the refusal\n    // is asynchronous the constructor below cannot fail open on it — so it is\n    // recorded here instead and read before wrapping anything else.\n    //\n    // A worker running the payload is itself proof that its document admits\n    // them, which is why the nested install starts answered.\n    var _blobRefused = false;\n    var _blobProven = !watchCsp;\n\n    // Wrappers handed out before the answer is known. A wrapper the CSP\n    // refuses fails asynchronously, long after its constructor returned, so\n    // the fail-open branch cannot see it and the page is left holding a worker\n    // that never starts. Each entry rebuilds one of those on the site's own\n    // script, or drops its bookkeeping once blob: workers are known to run.\n    var _pending = [];\n    function settle(refused) {\n      var armed = _pending;\n      _pending = [];\n      for (var i = 0; i < armed.length; i++) {\n        try { armed[i](refused); } catch (e) {}\n      }\n    }\n    function markRefused() {\n      if (_blobRefused || _blobProven) return;\n      _blobRefused = true;\n      settle(true);\n    }\n    function markProven() {\n      if (_blobProven) return;\n      _blobProven = true;\n      settle(false);\n    }\n\n    // Shared by both rescues: shadow one of [w]'s own methods with [fn],\n    // stringifying as the native one it stands in for.\n    function own(w, name, fn) {\n      try {\n        Object.defineProperty(w, name, {\n          value: asNative(fn, name), writable: true, configurable: true });\n      } catch (e) {}\n    }\n    // Registered before the page can hold the worker, so stopping the event\n    // here stops the page's handlers with it.\n    function swallow(ev) {\n      try { ev.preventDefault(); } catch (e) {}\n      try { ev.stopImmediatePropagation(); } catch (e) {}\n    }\n    // The page's messages are recorded rather than withheld: holding them\n    // until the answer arrives would delay every worker on every site to buy\n    // the refused one. The cap bounds a worker that is never answered for at\n    // all, since a refusal always lands within a task or two of construction.\n    var RECORD_LIMIT = 32;\n\n    // Keeps [w] — the object the page already holds — usable whichever way the\n    // answer goes, by swapping a worker built on the site's own script in\n    // behind it. The page's handlers, its `instanceof`, and every reference it\n    // handed out survive, which re-issuing the constructor could not do.\n    function armRescue(Real, w, script, options) {\n      var post, term;\n      try {\n        post = w.postMessage;\n        term = w.terminate;\n        if (typeof post !== 'function' || typeof term !== 'function' ||\n            typeof w.addEventListener !== 'function') return;\n      } catch (e) { return; }\n\n      // 'waiting' until the answer lands, then 'kept' (blob: workers run here,\n      // or the page terminated this one) or 'swapped' (rebuilt behind [w]).\n      var state = 'waiting';\n      // The rebuilt worker once there is one. Everything [w] exposes reads it,\n      // so a reference the page took while waiting keeps working after a swap.\n      var real = null;\n      var sent = [];\n      var relaying = false;\n\n      own(w, 'postMessage', function () {\n        if (real) return real.postMessage.apply(real, arguments);\n        if (sent && sent.length < RECORD_LIMIT) {\n          sent.push(Array.prototype.slice.call(arguments));\n        }\n        return post.apply(w, arguments);\n      });\n      own(w, 'terminate', function () {\n        if (real) return real.terminate();\n        keep();\n        return term.call(w);\n      });\n\n      // A refused wrapper never reaches any script, so its error carries no\n      // message; an error thrown by the site's own worker code does, and is\n      // the page's to see. Unhooked once blob: workers are known to run, where\n      // a message-less error means the site's own script failed to load and\n      // the page must hear about it.\n      function onError(ev) {\n        if (relaying || ev.message) return;\n        swallow(ev);\n        // After a swap this is the refused wrapper's own error, arriving late\n        // for a worker the page never got to use.\n        if (state === 'waiting') markRefused();\n      }\n      // Anything this worker says is proof that its wrapper ran, which is the\n      // answer the document needed and the end of every arm on the page.\n      function onMessage() { if (!relaying) markProven(); }\n      try {\n        w.addEventListener('error', onError, true);\n        w.addEventListener('message', onMessage, true);\n      } catch (e) {}\n\n      function keep() {\n        state = 'kept';\n        sent = null;\n        try { delete w.postMessage; } catch (e) {}\n        try { delete w.terminate; } catch (e) {}\n        try { w.removeEventListener('error', onError, true); } catch (e) {}\n        try { w.removeEventListener('message', onMessage, true); } catch (e) {}\n      }\n      // Re-dispatched on [w] so the page's own handlers see it, and flagged\n      // while in flight so the listeners above do not read one back as the\n      // wrapper answering or failing.\n      function relay(type, e) {\n        relaying = true;\n        try {\n          w.dispatchEvent(type === 'error'\n            ? new ErrorEvent('error', { message: e.message,\n                filename: e.filename, lineno: e.lineno, colno: e.colno })\n            : new MessageEvent(type, { data: e.data, ports: e.ports }));\n        } catch (e2) {} finally { relaying = false; }\n      }\n      function swap() {\n        var built;\n        try { built = new Real(script, options); } catch (e) { keep(); return; }\n        state = 'swapped';\n        real = built;\n        built.onmessage = function (e) { relay('message', e); };\n        built.onmessageerror = function (e) { relay('messageerror', e); };\n        built.onerror = function (e) {\n          try { e.preventDefault(); } catch (e2) {}\n          relay('error', e);\n        };\n        try { term.call(w); } catch (e) {}\n        var queued = sent || [];\n        sent = null;\n        for (var i = 0; i < queued.length; i++) {\n          try { built.postMessage.apply(built, queued[i]); } catch (e) {}\n        }\n      }\n\n      _pending.push(function (refused) {\n        if (state !== 'waiting') return;\n        if (refused) swap(); else keep();\n      });\n    }\n\n    // The same trade for a `SharedWorker`, which cannot be swapped the same\n    // way: the page takes its `MessagePort` at construction and a port cannot\n    // be re-entangled with a second worker. So the page is handed one end of a\n    // channel of ours instead, and the other end is what moves.\n    function armSharedRescue(Real, w, script, options) {\n      var mine, theirs, target;\n      try {\n        if (typeof MessageChannel !== 'function') return;\n        target = w.port;\n        if (!target || typeof w.addEventListener !== 'function') return;\n        var chan = new MessageChannel();\n        theirs = chan.port1;\n        mine = chan.port2;\n        Object.defineProperty(w, 'port', {\n          value: theirs, writable: true, configurable: true });\n      } catch (e) { return; }\n\n      var state = 'waiting';\n      var sent = [];\n      var relaying = false;\n\n      // Ports ride along: a MessagePort cannot be cloned, so forwarding a\n      // message that carries one without its transfer list would throw and\n      // lose it. Buffers are copied rather than transferred, which costs a\n      // copy and breaks nothing.\n      function listen(port) {\n        port.onmessage = function (e) {\n          if (state === 'waiting') markProven();\n          try { mine.postMessage(e.data, e.ports || []); } catch (e2) {}\n        };\n        try { port.start(); } catch (e) {}\n      }\n      mine.onmessage = function (e) {\n        var ports = e.ports || [];\n        if (sent && sent.length < RECORD_LIMIT) sent.push([e.data, ports]);\n        try { target.postMessage(e.data, ports); } catch (e2) {}\n      };\n      try { mine.start(); } catch (e) {}\n      listen(target);\n\n      function onError(ev) {\n        if (relaying || ev.message) return;\n        swallow(ev);\n        if (state === 'waiting') markRefused();\n      }\n      try { w.addEventListener('error', onError, true); } catch (e) {}\n\n      _pending.push(function (refused) {\n        if (state !== 'waiting') return;\n        if (!refused) {\n          state = 'kept';\n          sent = null;\n          try { w.removeEventListener('error', onError, true); } catch (e) {}\n          return;\n        }\n        var built;\n        try { built = new Real(script, options); } catch (e) { return; }\n        state = 'swapped';\n        // The page holds [w], so the rebuilt worker's failures have to arrive\n        // there; the refused wrapper's own error keeps being swallowed above.\n        built.onerror = function (e) {\n          try { e.preventDefault(); } catch (e2) {}\n          relaying = true;\n          try {\n            w.dispatchEvent(new ErrorEvent('error', { message: e.message,\n              filename: e.filename, lineno: e.lineno, colno: e.colno }));\n          } catch (e2) {} finally { relaying = false; }\n        };\n        target = built.port;\n        listen(target);\n        var queued = sent || [];\n        sent = null;\n        for (var i = 0; i < queued.length; i++) {\n          try { target.postMessage(queued[i][0], queued[i][1]); } catch (e) {}\n        }\n      });\n    }\n\n    // The one time the platform hands a page its own policy is inside a\n    // violation report, whichever rule was broken, so read it there rather\n    // than inferring an answer from the refusal in front of us. A report-only\n    // policy blocks nothing and must not be read as a refusal.\n    function watchCspViolations() {\n      if (typeof document === 'undefined' || !document.addEventListener) return;\n      document.addEventListener('securitypolicyviolation', function (e) {\n        if (e.disposition && e.disposition !== 'enforce') return;\n        var verdict = policyAdmitsBlobWorkers(String(e.originalPolicy || ''));\n        if (verdict === true) { markProven(); return; }\n        if (verdict === false) { markRefused(); return; }\n        // No policy text on the event: fall back to what this refusal says on\n        // its own. Only the directives that govern worker scripts count —\n        // chromium names the effective one, so a policy that reaches workers\n        // through `script-src` still reports `worker-src` here, and a refused\n        // blob: *script* stays what it is.\n        var blocked = String(e.blockedURI || '');\n        if (blocked !== 'blob' && blocked.indexOf('blob:') !== 0) return;\n        var directive = String(e.effectiveDirective || e.violatedDirective || '');\n        if (/^(worker|child)-src/.test(directive)) markRefused();\n      }, true);\n    }\n\n    // true / false / null when the policy says nothing about worker scripts.\n    // Worker scripts fall back worker-src -> child-src -> script-src ->\n    // default-src, and a `blob:` URL is admitted only by the scheme source\n    // itself: neither `*` nor `'self'` covers it.\n    function policyAdmitsBlobWorkers(policy) {\n      if (!policy) return null;\n      var answer = null;\n      var policies = policy.split(',');\n      for (var p = 0; p < policies.length; p++) {\n        var directives = policies[p].split(';');\n        var rank = -1;\n        var sources = null;\n        for (var i = 0; i < directives.length; i++) {\n          var parts = directives[i].trim().split(/\\s+/);\n          var name = (parts[0] || '').toLowerCase();\n          var r = name === 'worker-src' ? 3 : name === 'child-src' ? 2 :\n                  name === 'script-src' ? 1 : name === 'default-src' ? 0 : -1;\n          if (r > rank) { rank = r; sources = parts.slice(1); }\n        }\n        if (rank < 0) continue;\n        var admits = false;\n        for (var j = 0; j < sources.length; j++) {\n          if (sources[j].toLowerCase() === 'blob:') { admits = true; break; }\n        }\n        // Every policy delivered has to admit it; one refusal is the answer.\n        if (!admits) return false;\n        answer = true;\n      }\n      return answer;\n    }\n\n    function wrap(script, isModule) {\n      // Null hands the page's own script to the real constructor: unshimmed,\n      // but a worker that starts (WORK-006).\n      if (_blobRefused) return null;\n      var abs = new URL(String(script), globalThis.location.href).href;\n      var key = (isModule ? 'm:' : 'c:') + abs;\n      var hit = _wrapped.get(key);\n      if (hit) return hit;\n      var shimUrl = getShimUrl();\n      if (!shimUrl) return null;\n      var body;\n      if (isModule) {\n        // Static imports evaluate in source order, so the shim is fully applied\n        // before the original module body runs. Dynamic import() would resolve\n        // in a later task and could lose messages posted meanwhile.\n        //\n        // `__wsShimUrl` has to arrive via its own imported module: an\n        // assignment in this body would run *after* both imports (module\n        // evaluation is hoisted), so the shim's tail would find nothing and\n        // skip re-installing the Worker patch — leaving anything this module\n        // worker spawns unshimmed.\n        var setter = URL.createObjectURL(new Blob(\n          ['globalThis.__wsShimUrl = ' + JSON.stringify(shimUrl) + ';\\n'],\n          { type: 'text/javascript' }));\n        body = 'import ' + JSON.stringify(setter) + ';\\n' +\n               'import ' + JSON.stringify(shimUrl) + ';\\n' +\n               'import ' + JSON.stringify(abs) + ';\\n';\n      } else {\n        // The shim import is caught, the original's is not: a CSP that\n        // admits blob: workers but not blob: scripts must cost the spoof,\n        // never the site's worker. The handle goes with it, so a scope the\n        // payload never reached is not left with an own-property to find.\n        body = 'self.__wsShimUrl = ' + JSON.stringify(shimUrl) + ';\\n' +\n               'try { importScripts(' + JSON.stringify(shimUrl) + '); }\\n' +\n               'catch (e) { try { delete self.__wsShimUrl; } catch (e2) {} }\\n' +\n               'importScripts(' + JSON.stringify(abs) + ');\\n';\n      }\n      var url = URL.createObjectURL(new Blob([body], { type: 'text/javascript' }));\n      _wrapped.set(key, url);\n      return url;\n    }\n\n    function patch(name) {\n      var Real = globalThis[name];\n      if (typeof Real !== 'function') return;\n      var Patched = function (script, options) {\n        try {\n          var isModule = !!(options && options.type === 'module');\n          var url = wrap(script, isModule);\n          if (url) {\n            var w = new Real(url, options);\n            // Nothing to rescue once blob: workers are known to run here.\n            if (!_blobProven) {\n              if (name === 'Worker') armRescue(Real, w, script, options);\n              else armSharedRescue(Real, w, script, options);\n            }\n            return w;\n          }\n        } catch (e) {}\n        // Fail open: a broken worker is worse than an unspoofed one.\n        return new Real(script, options);\n      };\n      try { Patched.prototype = Real.prototype; } catch (e) {}\n      // Re-point the inherited own `constructor`: otherwise\n      // `Worker.prototype.constructor` is still the real constructor and a\n      // worker built through it never loads the shim payload.\n      try {\n        Object.defineProperty(Patched.prototype, 'constructor',\n          { value: Patched, writable: true, configurable: true });\n      } catch (e) {}\n      try {\n        Object.defineProperty(Patched, 'name', { value: name, configurable: true });\n      } catch (e) {}\n      asNative(Patched, name);\n      try { globalThis[name] = Patched; } catch (e) {}\n    }\n\n    if (watchCsp) watchCspViolations();\n\n    patch('Worker');\n    patch('SharedWorker');\n  }\n\n(function() {\n  try {\n    var u = globalThis.__wsShimUrl;\n    try { delete globalThis.__wsShimUrl; } catch (e) {}\n    if (u) __wsInstallWorkerWrap(function() { return u; }, false);\n  } catch (e) {}\n})();\n";
  var _url = null;
  __wsInstallWorkerWrap(function() {
    if (_url === null) {
      _url = URL.createObjectURL(new Blob([PAYLOAD], { type: 'text/javascript' }));
    }
    return _url;
  }, true);
})();
