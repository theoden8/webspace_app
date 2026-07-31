// Engine-consistent navigator-identity shim.
//
// A per-site User-Agent changes only the wire-level `User-Agent` header and
// (for desktop UAs) the surfaces `desktop_mode_shim.dart` patches. It does NOT
// change the navigator fields the JS engine itself populates — `vendor`,
// `vendorSub`, `productSub`, `oscpu`, `buildID`, `userAgentData` — nor
// `navigator.platform` on mobile. Those are set by the underlying WebView's
// real engine (WebKit on iOS, Blink on Android), so a spoofed UA whose engine
// disagrees with the host leaks a contradiction a fingerprinter (CreepJS,
// fingerprintjs) trivially catches: e.g. a Firefox-for-Android (Gecko) UA on
// an iOS WebView still reports `navigator.vendor = "Apple Computer, Inc."`
// (Firefox is `""`) and `navigator.platform = "iPhone"` (Firefox-Android is
// `"Linux armv8l"`).
//
// This shim derives the engine from the per-site UA ([inferUaEngine]) and
// forces the navigator identity fields to the values that engine really emits.
// Constants are engine-level (the same on every OS for a given engine) except
// `oscpu`/`platform`, which vary per OS. Values and their sources:
//
//   * vendor      Gecko "" · WebKit "Apple Computer, Inc." · Blink "Google Inc."
//   * vendorSub   "" on every engine
//   * productSub  Gecko "20100101" · WebKit/Blink "20030107"
//   * oscpu       Gecko only (absent elsewhere): desktop per-OS token,
//                 Firefox-Android frozen to "Linux armv8l" since FF123
//   * buildID     Gecko only (absent elsewhere): frozen "20181001000000"
//                 for web content since Firefox 64 (bug 583181)
//   * platform    mobile only (desktop is owned by desktop_mode_shim):
//                 Firefox/Chrome-Android "Linux armv8l", iOS WebKit "iPhone"
//   * userAgentData  Blink only; removed for Gecko/WebKit UAs
//
// `oscpu`, `buildID`, and `userAgentData` are *presence-sensitive*: a
// consistency check does `'oscpu' in navigator`, so on the engines that lack
// them the property must be genuinely absent, not defined as `undefined`. The
// shim deletes rather than stubs.
//
// Runs at DOCUMENT_START, `forMainFrameOnly: false`, for every per-site UA
// (desktop and mobile). It only touches identity fields; it does not overlap
// with `desktop_mode_shim.dart` (platform/userAgentData/maxTouchPoints for
// desktop, matchMedia pointer/hover, viewport) or the anti-fingerprinting
// shim.

import 'dart:convert';

import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity.dart';

/// Build the engine-consistent navigator-identity shim for [userAgent], or
/// `null` when the engine can't be classified (nothing to enforce) or the UA
/// is empty. Pure-Dart so it is reachable from `tool/dump_shim_js.dart` and
/// the drift check.
String? buildUserAgentIdentityShim(String userAgent) {
  final engine = inferUaEngine(userAgent);
  if (engine == UaEngine.unknown) return null;

  final os = describeUserAgent(userAgent).os;
  final isGecko = engine == UaEngine.gecko;
  final isMobile = !isDesktopUserAgent(userAgent);

  final vendor = switch (engine) {
    UaEngine.gecko => '',
    UaEngine.webkit => 'Apple Computer, Inc.',
    UaEngine.blink => 'Google Inc.',
    UaEngine.unknown => '',
  };
  final productSub = isGecko ? '20100101' : '20030107';

  final String? oscpu = isGecko
      ? switch (os) {
          UaOs.linux => 'Linux x86_64',
          UaOs.windows => 'Windows NT 10.0; Win64; x64',
          UaOs.macos => 'Intel Mac OS X 10.15',
          UaOs.android => 'Linux armv8l',
          _ => null,
        }
      : null;

  // Set for every UA we can place, not just mobile: worker scopes get this
  // shim but never `desktop_mode_shim` (which is window-only — viewport meta,
  // touch, pointer/hover matchMedia), so a desktop-UA worker would otherwise
  // report the host's real platform. On the page this re-asserts the value
  // `desktop_mode_shim` already set; both derive it from the same UA mapping,
  // so they cannot disagree.
  final String? platform = isMobile
      ? switch ((engine, os)) {
          (UaEngine.gecko, UaOs.android) => 'Linux armv8l',
          (UaEngine.blink, UaOs.android) => 'Linux armv8l',
          (UaEngine.webkit, UaOs.ios) => 'iPhone',
          _ => null,
        }
      : navigatorPlatformFor(inferDesktopUaPlatform(userAgent));

  // userAgentData exists only on Blink. Remove it for Gecko/WebKit UAs
  // (desktop_mode_shim already removes it for desktop UAs, so only mobile
  // needs it here).
  final removeUserAgentData = isMobile && engine != UaEngine.blink;

  final defs = <String>[
    "def('vendor', ${jsonEncode(vendor)});",
    "def('vendorSub', '');",
    "def('productSub', ${jsonEncode(productSub)});",
  ];

  if (isGecko) {
    if (oscpu != null) {
      defs.add("def('oscpu', ${jsonEncode(oscpu)});");
    } else {
      defs.add("removeProp('oscpu');");
    }
    defs.add("def('buildID', '20181001000000');");
  } else {
    defs.add("removeProp('oscpu');");
    defs.add("removeProp('buildID');");
  }

  if (platform != null) {
    defs.add("def('platform', ${jsonEncode(platform)});");
  }
  if (removeUserAgentData) {
    defs.add("removeProp('userAgentData');");
  }

  final defsJs = defs.map((d) => '  $d').join('\n');

  return '''
(function() {
  'use strict';
  if (globalThis.__ws_ua_identity_shim__) return;
  globalThis.__ws_ua_identity_shim__ = true;

  // Shared Function.prototype.toString funnel (same WeakMap as the other
  // shims) so every getter stringifies as `[native code]`.
  var _origFnToString = Function.prototype.toString;
  var _stubs = globalThis.__wsFnStubs || new WeakMap();
  globalThis.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}
    return fn;
  }
  if (!globalThis.__wsFnToStringPatched) {
    globalThis.__wsFnToStringPatched = true;
    var patched = function toString() {
      var stub = _stubs.get(this);
      return stub !== undefined ? stub : _origFnToString.call(this);
    };
    try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}
    try { Function.prototype.toString = patched; } catch (e) {}
  }

  // Resolved from the live `navigator` so this works unchanged in a worker,
  // where the class is WorkerNavigator and `Navigator` does not exist.
  var NavProto = (typeof navigator !== 'undefined' && navigator)
    ? Object.getPrototypeOf(navigator) : null;
  var IS_WORKER = typeof WorkerGlobalScope !== 'undefined' &&
    globalThis instanceof WorkerGlobalScope;

  // A worker's navigator legitimately carries a SMALLER surface than a
  // window's (no oscpu/buildID/plugins/...). Adding a property the real
  // WorkerNavigator lacks would be a fresh leak, so in worker scope we only
  // ever correct the VALUE of a property that is already there — never add.
  function present(name) {
    try {
      if (NavProto && (name in NavProto)) return true;
      return typeof navigator !== 'undefined' && navigator && (name in navigator);
    } catch (e) { return false; }
  }

  // Define on the navigator PROTOTYPE (never the instance — an own-property on
  // `navigator` would self-incriminate), matching how real engines carry
  // these accessors.
  function def(name, value) {
    if (!NavProto) return;
    if (IS_WORKER && !present(name)) return;
    try {
      Object.defineProperty(NavProto, name, {
        configurable: true, enumerable: true,
        get: asNative(function() { return value; }, name),
      });
    } catch (e) {}
  }

  // Make a property genuinely absent (delete), so `name in navigator` is
  // false. Falls back to an undefined getter only if the delete is refused
  // (non-configurable), which is still better than a populated value.
  function removeProp(name) {
    try { if (NavProto) delete NavProto[name]; } catch (e) {}
    try { delete navigator[name]; } catch (e) {}
    try {
      if (NavProto && (name in NavProto)) {
        Object.defineProperty(NavProto, name, {
          configurable: true, enumerable: false,
          get: asNative(function() { return undefined; }, name),
        });
      }
    } catch (e) {}
  }

$defsJs
})();
''';
}
