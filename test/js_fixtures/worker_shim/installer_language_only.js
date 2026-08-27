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

  var PAYLOAD = "(function() {\n  'use strict';\n  if (globalThis.__ws_language_shim__) return;\n  globalThis.__ws_language_shim__ = true;\n\n  var lang = \"en\";\n  var langs = Object.freeze([lang]);\n\n  // Shared Function.prototype.toString funnel (same WeakMap as the other\n  // shims) so every wrapper stringifies as `[native code]`.\n  var _origFnToString = Function.prototype.toString;\n  var _stubs = globalThis.__wsFnStubs || new WeakMap();\n  globalThis.__wsFnStubs = _stubs;\n  function asNative(fn, name) {\n    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}\n    return fn;\n  }\n  if (!globalThis.__wsFnToStringPatched) {\n    globalThis.__wsFnToStringPatched = true;\n    var patched = function toString() {\n      var stub = _stubs.get(this);\n      return stub !== undefined ? stub : _origFnToString.call(this);\n    };\n    try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}\n    try { Function.prototype.toString = patched; } catch (e) {}\n  }\n\n  // Resolved from the live `navigator` so this works unchanged in a worker,\n  // where the class is WorkerNavigator and `Navigator` does not exist.\n  var NavProto = (typeof navigator !== 'undefined' && navigator)\n    ? Object.getPrototypeOf(navigator) : null;\n\n  try {\n    if (NavProto) {\n      Object.defineProperty(NavProto, 'language', {\n        configurable: true, enumerable: true,\n        get: asNative(function language() { return lang; }, 'language'),\n      });\n      Object.defineProperty(NavProto, 'languages', {\n        configurable: true, enumerable: true,\n        get: asNative(function languages() { return langs; }, 'languages'),\n      });\n    }\n  } catch (e) {}\n\n  // True when the caller omitted the `locales` argument (or passed an empty\n  // list) — the only case in which a real engine falls back to the default\n  // locale, and thus the only case we override.\n  function localeOmitted(args) {\n    if (args.length === 0) return true;\n    var l = args[0];\n    return l === undefined || (Array.isArray(l) && l.length === 0);\n  }\n\n  // Wrap an Intl constructor so an omitted `locales` defaults to `lang`\n  // instead of the OS locale. Both `resolvedOptions().locale` and the\n  // formatted output then reflect the per-site tag. Delegates to whatever\n  // `Intl[name]` currently is, so it composes with the location shim's\n  // `Intl.DateTimeFormat` timezone wrapper regardless of injection order.\n  function wrapIntlCtor(name) {\n    try {\n      if (typeof Intl === 'undefined') return;\n      var Native = Intl[name];\n      if (typeof Native !== 'function') return;\n      function Wrapped() {\n        var args = localeOmitted(arguments)\n          ? [lang].concat(Array.prototype.slice.call(arguments, 1))\n          : arguments;\n        // Called without `new`: mirror the native behaviour exactly —\n        // DateTimeFormat/NumberFormat/Collator return an instance, the\n        // others throw. `Native.apply(null, ...)` reproduces both.\n        if (!(this instanceof Wrapped)) return Native.apply(null, args);\n        switch (args.length) {\n          case 0: return new Native();\n          case 1: return new Native(args[0]);\n          default: return new Native(args[0], args[1]);\n        }\n      }\n      Wrapped.prototype = Native.prototype;\n      if (typeof Native.supportedLocalesOf === 'function') {\n        Wrapped.supportedLocalesOf = asNative(function supportedLocalesOf() {\n          return Native.supportedLocalesOf.apply(Native, arguments);\n        }, 'supportedLocalesOf');\n      }\n      asNative(Wrapped, name);\n      try { Intl[name] = Wrapped; } catch (e) {}\n    } catch (e) {}\n  }\n\n  [\n    'DateTimeFormat', 'NumberFormat', 'RelativeTimeFormat', 'DisplayNames',\n    'ListFormat', 'PluralRules', 'Collator', 'Segmenter',\n  ].forEach(wrapIntlCtor);\n\n  // Date/Number toLocale* fall back to the default locale when called with no\n  // (or `undefined`) first argument. Inject `lang` there too so a locale-less\n  // `date.toLocaleString()` matches the Intl output above.\n  function wrapLocaleMethod(proto, method) {\n    try {\n      if (!proto) return;\n      var orig = proto[method];\n      if (typeof orig !== 'function') return;\n      var wrapped = function () {\n        if (arguments.length === 0 || arguments[0] === undefined) {\n          return orig.call(this, lang, arguments[1]);\n        }\n        return orig.apply(this, arguments);\n      };\n      asNative(wrapped, method);\n      try { proto[method] = wrapped; } catch (e) {}\n    } catch (e) {}\n  }\n  wrapLocaleMethod(Date.prototype, 'toLocaleString');\n  wrapLocaleMethod(Date.prototype, 'toLocaleDateString');\n  wrapLocaleMethod(Date.prototype, 'toLocaleTimeString');\n  wrapLocaleMethod(Number.prototype, 'toLocaleString');\n})();\n  function __wsInstallWorkerWrap(getShimUrl, watchCsp) {\n    if (globalThis.__ws_worker_shim__) return;\n    globalThis.__ws_worker_shim__ = true;\n\n    var _origFnToString = Function.prototype.toString;\n    var _stubs = globalThis.__wsFnStubs || new WeakMap();\n    globalThis.__wsFnStubs = _stubs;\n    function asNative(fn, name) {\n      try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}\n      return fn;\n    }\n    // Patch toString here rather than leaning on a sibling shim having done it:\n    // the patched constructors are the most obvious thing a fingerprinter\n    // stringifies, and this installer must not depend on injection order.\n    if (!globalThis.__wsFnToStringPatched) {\n      globalThis.__wsFnToStringPatched = true;\n      var patched = function toString() {\n        var stub = _stubs.get(this);\n        return stub !== undefined ? stub : _origFnToString.call(this);\n      };\n      try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}\n      try { Function.prototype.toString = patched; } catch (e) {}\n    }\n\n    // Cache wrapped URLs per (script, type). SharedWorker identity is keyed on\n    // the script URL, so handing out a fresh blob per call would turn one\n    // shared worker into N unshared ones and break the page.\n    var _wrapped = new Map();\n\n    // Whether this document's CSP admits a `blob:` worker script at all.\n    // Refused means every wrapper is dead on arrival, and because the refusal\n    // is asynchronous the constructor below cannot fail open on it — so it is\n    // recorded here instead and read before wrapping anything else.\n    var _blobRefused = false;\n    var _blobProven = false;\n\n    // Starts one throwaway worker: a message back proves `blob:` workers run\n    // here, an error proves the CSP refuses them. Runs at document start so\n    // the answer is in before the site builds a worker of its own.\n    function probeBlobWorkers() {\n      var Real = globalThis.Worker;\n      if (typeof Real !== 'function') return;\n      try {\n        var url = URL.createObjectURL(new Blob(\n          ['postMessage(1);close();'], { type: 'text/javascript' }));\n        var probe = new Real(url);\n        var finish = function (refused) {\n          if (refused && !_blobProven) _blobRefused = true;\n          if (!refused) _blobProven = true;\n          try { probe.terminate(); } catch (e) {}\n          // Only ever after the load settled: revoking while the script is\n          // still in flight would fail the probe on a page that was fine.\n          try { URL.revokeObjectURL(url); } catch (e) {}\n        };\n        probe.onmessage = function () { finish(false); };\n        probe.onerror = function (e) {\n          try { e.preventDefault(); } catch (e2) {}\n          finish(true);\n        };\n      } catch (e) {\n        _blobRefused = true;\n      }\n    }\n\n    // Covers the window before the probe answers, and the directives it does\n    // not exercise: a refused `blob:` under anything that governs worker\n    // scripts says what the probe would have said. Ignored once the probe has\n    // seen a blob worker run, so a site that blocks blob *scripts* while\n    // allowing blob *workers* keeps its workers shimmed.\n    function watchBlobRefusals() {\n      if (typeof document === 'undefined' || !document.addEventListener) return;\n      document.addEventListener('securitypolicyviolation', function (e) {\n        var blocked = String(e.blockedURI || '');\n        if (blocked !== 'blob' && blocked.indexOf('blob:') !== 0) return;\n        var directive = String(e.effectiveDirective || e.violatedDirective || '');\n        if (/^(worker|child|script|default)-src/.test(directive) && !_blobProven) {\n          _blobRefused = true;\n        }\n      }, true);\n    }\n\n    function wrap(script, isModule) {\n      // Null hands the page's own script to the real constructor: unshimmed,\n      // but a worker that starts (WORK-006).\n      if (_blobRefused) return null;\n      var abs = new URL(String(script), globalThis.location.href).href;\n      var key = (isModule ? 'm:' : 'c:') + abs;\n      var hit = _wrapped.get(key);\n      if (hit) return hit;\n      var shimUrl = getShimUrl();\n      if (!shimUrl) return null;\n      var body;\n      if (isModule) {\n        // Static imports evaluate in source order, so the shim is fully applied\n        // before the original module body runs. Dynamic import() would resolve\n        // in a later task and could lose messages posted meanwhile.\n        //\n        // `__wsShimUrl` has to arrive via its own imported module: an\n        // assignment in this body would run *after* both imports (module\n        // evaluation is hoisted), so the shim's tail would find nothing and\n        // skip re-installing the Worker patch — leaving anything this module\n        // worker spawns unshimmed.\n        var setter = URL.createObjectURL(new Blob(\n          ['globalThis.__wsShimUrl = ' + JSON.stringify(shimUrl) + ';\\n'],\n          { type: 'text/javascript' }));\n        body = 'import ' + JSON.stringify(setter) + ';\\n' +\n               'import ' + JSON.stringify(shimUrl) + ';\\n' +\n               'import ' + JSON.stringify(abs) + ';\\n';\n      } else {\n        // The shim import is caught, the original's is not: a CSP that\n        // admits blob: workers but not blob: scripts must cost the spoof,\n        // never the site's worker. The handle goes with it, so a scope the\n        // payload never reached is not left with an own-property to find.\n        body = 'self.__wsShimUrl = ' + JSON.stringify(shimUrl) + ';\\n' +\n               'try { importScripts(' + JSON.stringify(shimUrl) + '); }\\n' +\n               'catch (e) { try { delete self.__wsShimUrl; } catch (e2) {} }\\n' +\n               'importScripts(' + JSON.stringify(abs) + ');\\n';\n      }\n      var url = URL.createObjectURL(new Blob([body], { type: 'text/javascript' }));\n      _wrapped.set(key, url);\n      return url;\n    }\n\n    function patch(name) {\n      var Real = globalThis[name];\n      if (typeof Real !== 'function') return;\n      var Patched = function (script, options) {\n        try {\n          var isModule = !!(options && options.type === 'module');\n          var url = wrap(script, isModule);\n          if (url) return new Real(url, options);\n        } catch (e) {}\n        // Fail open: a broken worker is worse than an unspoofed one.\n        return new Real(script, options);\n      };\n      try { Patched.prototype = Real.prototype; } catch (e) {}\n      try {\n        Object.defineProperty(Patched, 'name', { value: name, configurable: true });\n      } catch (e) {}\n      asNative(Patched, name);\n      try { globalThis[name] = Patched; } catch (e) {}\n    }\n\n    if (watchCsp) {\n      watchBlobRefusals();\n      probeBlobWorkers();\n    }\n\n    patch('Worker');\n    patch('SharedWorker');\n  }\n\n(function() {\n  try {\n    var u = globalThis.__wsShimUrl;\n    try { delete globalThis.__wsShimUrl; } catch (e) {}\n    if (u) __wsInstallWorkerWrap(function() { return u; }, false);\n  } catch (e) {}\n})();\n";
  var _url = null;
  __wsInstallWorkerWrap(function() {
    if (_url === null) {
      _url = URL.createObjectURL(new Blob([PAYLOAD], { type: 'text/javascript' }));
    }
    return _url;
  }, true);
})();
