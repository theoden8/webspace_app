/// What every webview that runs as a site applies: the site's own webview, a
/// nested screen one of its links opens, and a popup either of them spawns.
///
/// Resolved once, tracking protection and the archive tier included, by
/// `WebViewModel.sitePosture`, and handed whole to each surface. Every field
/// is required with no default, so a new per-site setting does not compile
/// until that one resolver says what it is, and no surface can be built
/// without it (CLAUDE.md, "Per-site settings MUST apply to nested webviews").
library;

import 'package:meta/meta.dart';

import 'package:webspace/settings/blocked_cookie.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/http_auth_memory.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

/// The store the site binds and what it keeps there.
typedef SiteContainer = ({
  // Stands in for the siteId in the on-disk container name (ARCH-007).
  String? archiveContainerId,
  bool incognito,
  // Outbound form: a Tor proxy carries the siteId as its isolation tag.
  UserProxySettings proxy,
  bool thirdPartyCookies,
  HttpAuthMemory httpAuthMemory,
  bool passkeys,
});

/// What is refused or rewritten before it reaches the network.
typedef SiteBlocking = ({
  bool clearUrls,
  bool dns,
  // Null follows the app-wide level.
  int? dnsLevel,
  bool contentBlock,
  // Serve CDN sub-resources from the app-wide cache (Android only).
  bool localCdn,
  bool httpsUpgrade,
  // Whether block events roll into the app-wide report (STATS-001).
  bool contributesStats,
  Set<BlockedCookie> blockedCookies,
});

/// The anti-fingerprinting surface (ETP).
typedef SiteFingerprint = ({
  bool trackingProtection,
  bool letterbox,
  int? windowWidth,
  int? windowHeight,
  String? resetNonce,
});

/// Capture and DRM decisions, as the site has settled them.
typedef SiteMedia = ({CaptureGrants capture, bool? protectedContent});

/// How pages are run and presented.
typedef SitePage = ({
  bool javascript,
  String? userAgent,
  String? language,
  int zoomPercent,
  List<UserScriptConfig> userScripts,
  ExternalLinkMode externalLinks,
  bool notifications,
});

@immutable
final class SitePosture {
  const SitePosture({
    required this.siteId,
    required this.container,
    required this.blocking,
    required this.fingerprint,
    required this.location,
    required this.media,
    required this.page,
  });

  final String siteId;
  final SiteContainer container;
  final SiteBlocking blocking;
  final SiteFingerprint fingerprint;
  final SiteLocation location;
  final SiteMedia media;
  final SitePage page;

  /// The posture a nested screen starts from. Identical but for one thing: a
  /// `real` capture grant answered a popup that named the opening site's top
  /// document, so a page reached through a link is asked for itself
  /// (CAM-005 / MIC-005, SEC-007). Every other decision is inherited.
  SitePosture forNested() => SitePosture(
    siteId: siteId,
    container: container,
    blocking: blocking,
    fingerprint: fingerprint,
    location: location,
    page: page,
    media: (
      capture: media.capture.withoutRealGrants(),
      protectedContent: media.protectedContent,
    ),
  );
}

/// Opens [url] in a nested `InAppWebViewScreen` that runs as the opening
/// site, under [posture] (see [SitePosture], which a new per-site field joins
/// rather than this signature). Implemented by `_WebSpacePageState.launchUrl`.
typedef LaunchUrlFunc = void Function(
  String url, {
  required SitePosture posture,
  String? homeTitle,
});
