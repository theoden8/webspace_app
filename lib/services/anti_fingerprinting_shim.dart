import 'dart:math';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:webspace/services/page_js.dart';

/// Compute the seed string passed to [buildAntiFingerprintingShim].
///
/// Non-incognito sites seed with `siteId` verbatim — the fingerprint stays
/// stable across launches (ETP-004 baseline).
///
/// Incognito sites mix in a process-lifetime [launchNonce] (typically
/// `LaunchNonce.value`) so the fingerprint is stable within a single app
/// session — no flicker on iframe re-injection or nested webview opens —
/// but randomizes across cold restarts. The `incognito` flag already implies
/// the user wants a fresh-visitor posture each launch; reusing the same
/// fingerprint across launches would itself be a stable cross-session
/// identifier (issue #327, ETP-028).
///
/// [resetNonce], when non-empty, is a per-site value regenerated whenever the
/// user clears the site's data (ETP-022). Folding it into the seed rerolls
/// the entire fingerprint (canvas/WebGL/audio/window size/…) so a site can't
/// re-identify the user across a data wipe via a stable fingerprint. When
/// null/empty the seed is unchanged, so sites stored before this field
/// existed keep their fingerprint until the user resets them.
String computeAntiFingerprintingSeed({
  required String siteId,
  required bool incognito,
  required String launchNonce,
  String? resetNonce,
}) {
  final base = (resetNonce != null && resetNonce.isNotEmpty)
      ? '$siteId:$resetNonce'
      : siteId;
  return incognito ? '$base:$launchNonce' : base;
}

/// The anti-fingerprinting shim for the given site configuration, or `null`
/// if the umbrella is off / no siteId is set.
///
/// Lives alongside [computeAntiFingerprintingSeed] so the entire chain —
/// gate → seed derivation → shim text — is exercisable from `flutter test`
/// without standing up `WebViewFactory.createWebView`.
String? buildAntiFingerprintingScriptSource({
  required String? siteId,
  required bool trackingProtectionEnabled,
  required bool incognito,
  required String launchNonce,
  String? resetNonce,
  bool letterbox = false,
}) {
  if (!trackingProtectionEnabled || siteId == null) return null;
  final seed = computeAntiFingerprintingSeed(
    siteId: siteId,
    incognito: incognito,
    launchNonce: launchNonce,
    resetNonce: resetNonce,
  );
  return buildAntiFingerprintingShim(opaqueAntiFingerprintingSeed(seed),
      letterbox: letterbox);
}

/// The seed the page actually sees. [computeAntiFingerprintingSeed] names
/// the record (`siteId`, the reset nonce, the launch nonce) and the shim
/// text is copied into the worker payload, where page script can read it
/// back through `URL.createObjectURL`, so the identifiers are digested
/// first: the same input still yields the same fingerprint, a reroll still
/// rerolls, and two incognito sites in one launch share nothing a tracker
/// can join on.
String opaqueAntiFingerprintingSeed(String seed) =>
    sha256.convert(utf8.encode('ws-afp:$seed')).toString();

/// Build the per-site anti-fingerprinting shim seeded by [seed]. The seed
/// is computed via [computeAntiFingerprintingSeed] — siteId-only for
/// non-incognito (stable per site) or `siteId:launchNonce` for incognito
/// (stable per session, randomized per launch).
///
/// When [letterbox] is true the site's WebView has been physically sized to a
/// bucketed box by Flutter, so `window.inner*` is already truthful; the shim
/// then makes `screen.*` mirror `window.inner*` (instead of the fixed
/// 1920x1080) so the two stay consistent. When false, `screen.*` keeps the
/// fixed desktop dimensions (ETP-010) and window size is left untouched.
String buildAntiFingerprintingShim(
  String seed, {
  bool letterbox = false,
}) =>
    PageJs.antiFingerprinting.withConfig({
      'seed': seed,
      'letterbox': letterbox,
    });

/// Generates a fresh per-site fingerprint reset nonce. Uses [Random.secure]
/// so a site can't predict the post-reset fingerprint.
String generateFingerprintResetNonce() {
  final rng = Random.secure();
  final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
