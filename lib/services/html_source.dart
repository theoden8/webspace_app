/// How a site's webview takes its first page.
///
/// This classification MUST be identical everywhere it's used, or a site can
/// render blank (preloaded from one store, read from another). The call sites:
///   - preload: `SiteActivationController.ensureSiteHtmlForModel` decrypts a
///     file import before the site's webview builds.
///   - read: `SiteWebViewStack` hands the import's bytes to the build, and
///     asks [loadsCacheFirst] whether a URL site starts from the engine's
///     cache.
/// See test/html_source_test.dart.
library;

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/file_import_document.dart';

enum HtmlSource {
  /// `file://` imports — the only copy of user-supplied content, in
  /// `HtmlImportStorage`. Rendered from those bytes always (no live to fetch).
  import,

  /// URL sites, whose first load may come from the engine's own HTTP cache
  /// ([loadsCacheFirst]).
  cache,

  /// Incognito + archive-tier sites always load live.
  none,
}

/// Classify a site's HTML store from the fields that determine it. Pure: no
/// Flutter, no I/O — safe to unit-test and to call on every build.
HtmlSource htmlSourceFor({
  required bool incognito,
  required bool isArchiveTier,
  required String initUrl,
}) {
  if (incognito || isArchiveTier) return HtmlSource.none;
  if (isFileImportUrl(initUrl)) return HtmlSource.import;
  return HtmlSource.cache;
}

/// Whether a site's webview takes its first page from the engine's cache,
/// then loads it live once the network answers: always when the site keeps
/// its HTML (HTML caching), and when the last probe found no network. [online]
/// is that probe's answer, null before one has run. [engineCan] is
/// [engineLoadsCacheFirst] on this platform.
bool loadsCacheFirst(
  HtmlSource source, {
  required bool htmlCaching,
  required bool? online,
  required bool engineCan,
}) =>
    engineCan &&
    source == HtmlSource.cache &&
    (htmlCaching || !(online ?? true));

/// Whether this platform's webview can load a page from its cache first:
/// Android and Apple's WebKit can be told to; WPE has no per-load cache
/// policy, so Linux loads live.
bool get engineLoadsCacheFirst => hostIsAndroid || hostIsIOS || hostIsMacOS;
