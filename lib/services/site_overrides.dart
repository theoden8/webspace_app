/// The per-site override rules: what a site runs with, as a pure function of
/// what it stores and what overrides it. WebViewModel's `effective*` getters
/// and the settings screens both read them, so what a screen shows is what
/// the webview runs with, and each rule is stated once.
library;

import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';

/// What Tracking Protection holds a subordinate setting at while it is on.
/// The stored value survives underneath, so turning the umbrella off restores
/// the user's own choice rather than resetting it.
enum TrackingProtectionForce {
  /// ETP-002: the four list-based blockers.
  clearUrls(true),
  dnsBlock(true),
  contentBlock(true),
  localCdn(true),

  /// ETP-030: turning the umbrella off to make a site work must not be what
  /// moves a login page to cleartext, so off leaves the stored value.
  httpsUpgrade(true),

  /// ETP-024: the oldest cross-site tracking channel, forced off.
  thirdPartyCookies(false),

  /// ETP-023: a provisioned Widevine identifier outlives every reset.
  protectedContent(false);

  const TrackingProtectionForce(this.forcedTo);

  final bool forcedTo;

  bool resolve({required bool stored,required bool trackingProtection}) =>
      trackingProtection ? forcedTo : stored;
}

/// ARCH-006: an archive-tier site never reaches OS-level UI, a device, or
/// disk outside the archive's keyspace. Each fold keeps the stored value for
/// when the site leaves the archive.
abstract final class ArchiveFold {
  /// The capture popups, the file picker and Android's OS permission dialog
  /// are OS-level UI, so every kind is blocked without prompting.
  static CaptureGrants captures(
    CaptureGrants stored, {
    required bool archived,
  }) => archived ? stored.blocked() : stored;

  static bool notifications({required bool stored,required bool archived}) =>
      stored && !archived;

  static bool backgroundAudio({required bool stored,required bool archived}) =>
      stored && !archived;

  static bool localCdn({required bool stored,required bool archived}) =>
      stored && !archived;

  static bool htmlCaching({required bool stored,required bool archived}) =>
      stored && !archived;

  static bool incognito({required bool stored,required bool archived}) =>
      stored || archived;

  /// Both blocker masks leave a trace outside the archive's keyspace: a
  /// per-site level pins a downloaded level file, a per-site list selection
  /// rewrites the shared engine cache. Archive sites run the app-wide ones.
  static int? dnsBlockLevel(int? stored, {required bool archived}) =>
      archived ? null : stored;

  static Set<String> disabledFilterLists(Set<String> stored,
          {required bool archived}) =>
      archived ? const <String>{} : stored;

  /// Launching the system browser crosses the archive's isolation boundary;
  /// blocking crosses nothing and stays.
  static ExternalLinkMode externalLinks(
    ExternalLinkMode stored, {
    required bool archived,
  }) => archived && stored == ExternalLinkMode.browser
      ? ExternalLinkMode.inApp
      : stored;
}

/// Protected content (Widevine/EME): denied without a prompt on an
/// archive-tier site and under Tracking Protection; otherwise the stored
/// decision, null being "ask".
bool? resolveProtectedContent({
  required bool? stored,
  required bool archived,
  required bool trackingProtection,
}) => archived || trackingProtection ? false : stored;

/// A kiosk site runs as one page, never with tabs (TAB-013).
bool resolveTabs({required bool tabs, required bool kiosk}) => tabs && !kiosk;

/// Routing is an option of the in-app mode (LIR-014).
bool resolveRouteOutboundLinks({
  required bool route,
  required ExternalLinkMode mode,
}) => route && mode == ExternalLinkMode.inApp;

/// Incognito drops the stored URL on every restart, so the site opens at its
/// home page whatever Always open Home stores.
bool resolveAlwaysOpenHome({
  required bool alwaysOpenHome,
  required bool incognito,
}) => alwaysOpenHome || incognito;
