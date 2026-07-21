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

  // Desktop platform is owned by desktop_mode_shim; only fix mobile, where the
  // host engine's platform ("iPhone" / "Linux armv8l") may contradict the UA.
  final String? platform = isMobile
      ? switch ((engine, os)) {
          (UaEngine.gecko, UaOs.android) => 'Linux armv8l',
          (UaEngine.blink, UaOs.android) => 'Linux armv8l',
          (UaEngine.webkit, UaOs.ios) => 'iPhone',
          _ => null,
        }
      : null;

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
  if (window.__ws_ua_identity_shim__) return;
  window.__ws_ua_identity_shim__ = true;

  // Shared Function.prototype.toString funnel (same WeakMap as the other
  // shims) so every getter stringifies as `[native code]`.
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

  var NavProto = (typeof Navigator !== 'undefined') ? Navigator.prototype : null;

  // Define on Navigator.prototype (never the instance — an own-property on
  // `navigator` would self-incriminate), matching how real engines carry
  // these accessors.
  function def(name, value) {
    if (!NavProto) return;
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
