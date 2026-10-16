/// Which on-device HTML store backs a site's synchronous first-paint read.
///
/// This classification MUST be identical everywhere it's used, or a site can
/// render blank (preloaded from one store, read from another) or have its live
/// snapshot wrongly saved over a `file://` import. The call sites:
///   - preload: `SiteActivationController.ensureSiteHtmlForModel` decrypts
///     the right store before a site's webview builds, waiting for it only
///     when the build renders it ([rendersStoredHtml]).
///   - read: `SiteWebViewStack`'s `initialHtml` reads it synchronously.
///   - save: `onHtmlLoaded` / `shouldFetchHtml` persist live snapshots only for
///     [HtmlSource.cache] sites.
/// Centralising the rule here (instead of three inline `incognito || isArchive
/// || initUrl.startsWith('file://')` checks) makes the parity testable and
/// undriftable. See test/html_source_test.dart.
library;

enum HtmlSource {
  /// `file://` imports — the only copy of user-supplied content, in
  /// `HtmlImportStorage`. Rendered from cache always (no live to fetch).
  import,

  /// URL sites — re-fetchable snapshots in `HtmlCacheService`. Read is
  /// further gated by `htmlCachingEnabled`/offline at the call site.
  cache,

  /// Incognito + archive-tier sites never read or persist on-device HTML.
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
  if (initUrl.startsWith('file://')) return HtmlSource.import;
  return HtmlSource.cache;
}

/// Whether a webview built now starts from the site's stored HTML rather
/// than its live page: an import always, having no live page; a cached page
/// only when the site keeps its HTML or the device is offline, so an online
/// start never shows stale content. [online] is the last known state, null
/// when none is known yet.
bool rendersStoredHtml(
  HtmlSource source, {
  required bool htmlCachingEnabled,
  required bool? online,
}) =>
    switch (source) {
      HtmlSource.import => true,
      HtmlSource.cache => htmlCachingEnabled || !(online ?? true),
      HtmlSource.none => false,
    };
