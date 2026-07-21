// Per-site language override JavaScript shim.
//
// Sets `navigator.language`, `navigator.languages`, and — critically — forces
// the *actual* locale used by the whole `Intl` subsystem and the
// `Date`/`Number` `toLocale*` methods, so client-rendered SPAs (React i18n,
// date/number formatters) both report AND format in the per-site language
// instead of the OS locale.
//
// The naive approach (only relabelling `navigator.language` and
// `Intl.DateTimeFormat().resolvedOptions().locale`) is detectable: a
// fingerprinter reads `navigator.language` (spoofed) then formats a date /
// number with a locale-less `Intl` formatter and sees the OS locale in the
// output ("julio", "21 millones") — a contradiction. CreepJS flags exactly
// this. We instead inject the per-site tag as the default `locales` argument
// of every `Intl` constructor (and the `toLocale*` methods) whenever the
// caller omits it, so `resolvedOptions().locale` AND the formatted output are
// genuinely the per-site language. Sites that pass an explicit locale are
// left untouched (that is legitimate and real browsers honour it).
//
// Must be injected at DOCUMENT_START to beat the page's own JS read. The
// Accept-Language header on the wire is a separate axis; these JS surfaces
// don't follow it.

import 'dart:convert';

/// Build the language-override shim for [language] (e.g. `'en'`, `'fr-FR'`).
/// Pure-Dart so the shim string is reachable from `tool/dump_shim_js.dart`
/// and the drift check.
String buildLanguageShim(String language) {
  final encoded = jsonEncode(language);
  return '''
(function() {
  'use strict';
  if (window.__ws_language_shim__) return;
  window.__ws_language_shim__ = true;

  var lang = $encoded;
  var langs = Object.freeze([lang]);

  // Shared Function.prototype.toString funnel (same WeakMap as the other
  // shims) so every wrapper stringifies as `[native code]`.
  var _origFnToString = Function.prototype.toString;
  var _stubs = window.__wsFnStubs || new WeakMap();
  window.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}
    return fn;
  }
  if (!window.__wsFnToStringPatched) {
    window.__wsFnToStringPatched = true;
    var patched = function toString() {
      var stub = _stubs.get(this);
      return stub !== undefined ? stub : _origFnToString.call(this);
    };
    try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}
    try { Function.prototype.toString = patched; } catch (e) {}
  }

  try {
    Object.defineProperty(Navigator.prototype, 'language', {
      configurable: true, enumerable: true,
      get: asNative(function language() { return lang; }, 'language'),
    });
    Object.defineProperty(Navigator.prototype, 'languages', {
      configurable: true, enumerable: true,
      get: asNative(function languages() { return langs; }, 'languages'),
    });
  } catch (e) {}

  // True when the caller omitted the `locales` argument (or passed an empty
  // list) — the only case in which a real engine falls back to the default
  // locale, and thus the only case we override.
  function localeOmitted(args) {
    if (args.length === 0) return true;
    var l = args[0];
    return l === undefined || (Array.isArray(l) && l.length === 0);
  }

  // Wrap an Intl constructor so an omitted `locales` defaults to `lang`
  // instead of the OS locale. Both `resolvedOptions().locale` and the
  // formatted output then reflect the per-site tag. Delegates to whatever
  // `Intl[name]` currently is, so it composes with the location shim's
  // `Intl.DateTimeFormat` timezone wrapper regardless of injection order.
  function wrapIntlCtor(name) {
    try {
      if (typeof Intl === 'undefined') return;
      var Native = Intl[name];
      if (typeof Native !== 'function') return;
      function Wrapped() {
        var args = localeOmitted(arguments)
          ? [lang].concat(Array.prototype.slice.call(arguments, 1))
          : arguments;
        // Called without `new`: mirror the native behaviour exactly —
        // DateTimeFormat/NumberFormat/Collator return an instance, the
        // others throw. `Native.apply(null, ...)` reproduces both.
        if (!(this instanceof Wrapped)) return Native.apply(null, args);
        switch (args.length) {
          case 0: return new Native();
          case 1: return new Native(args[0]);
          default: return new Native(args[0], args[1]);
        }
      }
      Wrapped.prototype = Native.prototype;
      if (typeof Native.supportedLocalesOf === 'function') {
        Wrapped.supportedLocalesOf = asNative(function supportedLocalesOf() {
          return Native.supportedLocalesOf.apply(Native, arguments);
        }, 'supportedLocalesOf');
      }
      asNative(Wrapped, name);
      try { Intl[name] = Wrapped; } catch (e) {}
    } catch (e) {}
  }

  [
    'DateTimeFormat', 'NumberFormat', 'RelativeTimeFormat', 'DisplayNames',
    'ListFormat', 'PluralRules', 'Collator', 'Segmenter',
  ].forEach(wrapIntlCtor);

  // Date/Number toLocale* fall back to the default locale when called with no
  // (or `undefined`) first argument. Inject `lang` there too so a locale-less
  // `date.toLocaleString()` matches the Intl output above.
  function wrapLocaleMethod(proto, method) {
    try {
      if (!proto) return;
      var orig = proto[method];
      if (typeof orig !== 'function') return;
      var wrapped = function () {
        if (arguments.length === 0 || arguments[0] === undefined) {
          return orig.call(this, lang, arguments[1]);
        }
        return orig.apply(this, arguments);
      };
      asNative(wrapped, method);
      try { proto[method] = wrapped; } catch (e) {}
    } catch (e) {}
  }
  wrapLocaleMethod(Date.prototype, 'toLocaleString');
  wrapLocaleMethod(Date.prototype, 'toLocaleDateString');
  wrapLocaleMethod(Date.prototype, 'toLocaleTimeString');
  wrapLocaleMethod(Number.prototype, 'toLocaleString');
})();
''';
}
