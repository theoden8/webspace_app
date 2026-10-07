import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/platform/host_platform.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/anti_fingerprinting_shim.dart';
import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/services/blob_url_capture.dart';
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/block_interceptor_shim.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/clearurl_share_shim.dart';
import 'package:webspace/services/container_proxy_ledger.dart';
import 'package:webspace/services/do_not_track_shim.dart';
import 'package:webspace/services/html_snapshot.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/https_upgrade_engine.dart';
import 'package:webspace/services/language_shim.dart';
import 'package:webspace/services/launch_nonce.dart';
import 'package:webspace/services/letterbox.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/page_zoom_shim.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_coverage_engine.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/pull_to_refresh_gate.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/target_blank_rewrite.dart';
import 'package:webspace/services/webgl_kill_switch_shim.dart';
import 'package:webspace/services/theme_color_scheme_shim.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/content_blocker_shim.dart';
import 'package:webspace/services/generic_cosmetic_shim.dart';
import 'package:webspace/services/procedural_cosmetic_shim.dart';
import 'package:webspace/services/camera_permission_service.dart';
import 'package:webspace/services/capture_permission_engine.dart';
import 'package:webspace/services/capture_shim.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/passkey_native.dart';
import 'package:webspace/services/passkey_shim.dart';
import 'package:webspace/services/current_location_service.dart';
import 'package:webspace/services/desktop_mode_shim.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity_shim.dart';
import 'package:webspace/services/worker_shim.dart';
import 'package:webspace/services/user_agent_metadata_builder.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/icon_service.dart'
    show fetchPageIconBytes, fetchPageLinkedBytes;
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/download_engine.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/download_url_revert_engine.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/icon_link_watcher_shim.dart';
import 'package:webspace/services/opensearch_engine.dart';
import 'package:webspace/services/search_link_watcher_shim.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/site_icon_fetcher.dart';
import 'package:webspace/services/site_icon_native.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_shim.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/notification_polyfill_shim.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/widgets/surface_nudge_scope.dart';

// Re-export inapp.Cookie as Cookie for convenience
typedef Cookie = inapp.Cookie;

/// Translate WebSpace's [UserProxySettings] into the fork's
/// [`inapp.ProxySettings`] type, which the fork's
/// `preWKWebViewConfiguration` reads and applies to the per-WebView
/// `WKWebsiteDataStore.proxyConfigurations` (iOS 17+ / macOS 14+ only).
/// Returns null for `ProxyType.DEFAULT` or invalid configs so the
/// native side leaves any previously-set proxy in place; callers that
/// need to *clear* a proxy should pass an empty `ProxySettings`.
///
/// Credentials, when present, ride BOTH forms, because the two platforms
/// that read this field read different ones (PROXY-025).
///
/// Linux's `ProxyRule` carries only `url` and `schemeFilter`, so WPE gets
/// them as `scheme://user:pass@host:port` userinfo. Apple's
/// `ProxyRule.toProxyConfiguration` builds its endpoint from `URL.host` and
/// `URL.port` alone, which drops userinfo on the floor, and takes the
/// credential from the separate `username`/`password` fields instead --
/// they are what reach `ProxyConfiguration.applyCredential`. Sending only
/// the URL form is why a credentialed proxy on iOS/macOS authenticated with
/// nothing and drew a `407` the user could not act on.
@visibleForTesting
inapp.ProxySettings? userProxyToInappProxy(UserProxySettings settings) {
  if (settings.type == ProxyType.DEFAULT) return null;
  if (settings.type == ProxyType.TOR) {
    // TOR has no address until the runtime is up. A null expansion means
    // "not routable yet", and returning null here is what trips the
    // `proxyUnavailable` fail-closed branch below rather than loading the
    // page over the device IP.
    final expanded = expandTorProxy(settings);
    if (expanded == null) return null;
    return userProxyToInappProxy(expanded);
  }
  if (settings.type == ProxyType.SAVED ||
      settings.type == ProxyType.GATEWAY ||
      settings.credentialsId != null) {
    final route = resolveLibraryProxy(settings);
    if (route.type == ProxyType.SAVED) return null;
    return userProxyToInappProxy(route);
  }
  final parsed = splitProxyAddress(settings.address);
  if (parsed == null) return null;
  final host = parsed.host;
  final port = parsed.port;
  final scheme = switch (settings.type) {
    ProxyType.HTTPS => 'https',
    ProxyType.SOCKS5 => 'socks5',
    _ => 'http',
  };
  final auth = settings.hasCredentials
      ? '${Uri.encodeComponent(settings.username!)}:'
          '${Uri.encodeComponent(settings.password!)}@'
      : '';
  return inapp.ProxySettings(
    proxyRules: [
      inapp.ProxyRule(
        url: '$scheme://$auth$host:$port',
        username: settings.hasCredentials ? settings.username : null,
        password: settings.hasCredentials ? settings.password : null,
      )
    ],
  );
}

/// The proxy an Apple container store carries while router mode is active
/// (PROXY-026), or null when it is not.
///
/// Android points one process-wide `ProxyController` rule at the relay;
/// there is no such rule on Apple, so each store names the relay itself and
/// the site is told apart by the credential it presents. Every store gets
/// one, including a site whose own proxy is DEFAULT: the relay dials those
/// straight out, and a store left unproxied would miss the PROXY-015
/// attribution probe entirely and stand router mode down.
///
/// The credential goes in `ProxyRule.username`/`password`, never as URL
/// userinfo: the fork builds its `ProxyConfiguration` endpoint from
/// `URL.host` and `URL.port` alone, so userinfo never reaches
/// `applyCredential` (PROXY-025).
inapp.ProxySettings? routerRelayProxyFor({
  required String? siteId,
  required bool ownsContainer,
}) {
  // Only where the proxy is bound per store (PROXY-027). Under the
  // process-wide binding the router already rides that one rule -- Android's
  // `ProxyController` -- and a per-WebView `proxySettings` there would be a
  // second, conflicting source of truth for the same traffic.
  if (ProxyManager.binding != ProxyBinding.perSite) return null;
  final router = ProxyRouterService.instance;
  if (!router.isActive) return null;
  // No site id means no row in the route table, and the shared identity
  // belongs to a group this webview is not part of. Routing it there would
  // put it on another site's circuit, so fall back to its own rule.
  if (siteId == null || siteId.isEmpty) return null;
  final host = router.host;
  final port = router.port;
  if (host == null || port == null) return null;
  final identity = ProxyRouterEngine.identityFor(
    siteId: siteId,
    ownsContainer: ownsContainer,
  );
  final token = router.tokenFor(identity);
  if (token == null) return null;
  return inapp.ProxySettings(
    proxyRules: [
      inapp.ProxyRule(
        url: 'http://$host:$port',
        username: router.usernameFor(identity),
        password: token,
      )
    ],
    bypassRules: [],
  );
}

/// Extension to add JSON serialization to inapp.Cookie
extension CookieJson on inapp.Cookie {
  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'expiresDate': expiresDate,
    'isSecure': isSecure,
    'isHttpOnly': isHttpOnly,
    'isSessionOnly': isSessionOnly,
    'sameSite': sameSite?.toString(),
  };
}

/// Factory function to create Cookie from JSON
Cookie cookieFromJson(Map<String, dynamic> json) => inapp.Cookie(
  name: json['name'],
  value: json['value'],
  domain: json['domain'],
  path: json['path'],
  expiresDate: json['expiresDate'],
  isSecure: json['isSecure'],
  isHttpOnly: json['isHttpOnly'],
  isSessionOnly: json['isSessionOnly'],
  sameSite: json['sameSite'] != null
      ? inapp.HTTPCookieSameSitePolicy.values.firstWhere(
          (e) => e.toString() == json['sameSite'],
          orElse: () => inapp.HTTPCookieSameSitePolicy.LAX,
        )
      : null,
);

/// [cookieFromJson] for stored JSON: null, rather than a cast failure, unless
/// every field has the type the cookie takes.
Cookie? tryCookieFromJson(Object? json) {
  if (json is! Map<String, dynamic>) return null;
  if (json['name'] is! String ||
      json['domain'] is! String? ||
      json['path'] is! String? ||
      json['expiresDate'] is! int? ||
      json['isSecure'] is! bool? ||
      json['isHttpOnly'] is! bool? ||
      json['isSessionOnly'] is! bool? ||
      json['sameSite'] is! String?) {
    return null;
  }
  return cookieFromJson(json);
}

/// Cookie manager - thin wrapper around inapp.CookieManager
class CookieManager {
  final _manager = inapp.CookieManager.instance();

  Future<List<Cookie>> getCookies({required Uri url}) async =>
      _manager.getCookies(url: inapp.WebUri(url.toString()));

  /// Returns every cookie in the native jar regardless of URL scoping.
  /// `getCookies(url)` only returns cookies that would be sent with a request
  /// to that URL, which misses cookies scoped to sibling subdomains (e.g.
  /// `accounts.google.com` when querying with `mail.google.com`).
  ///
  /// Platform support for the underlying `WKHTTPCookieStore.getAllCookies()`
  /// is iOS/macOS only — Android's `CookieManager` has no "get all" endpoint.
  /// On Android, callers MUST pass [candidateUrls] (typically every loaded
  /// site's `initUrl` and `currentUrl`); the result is aggregated via
  /// per-URL `getCookies`, deduplicated by `(name, domain, path)`. This is
  /// a best-effort capture — cookies on subdomains of a candidate URL that
  /// aren't reachable from it (e.g. `accounts.google.com` when only
  /// `mail.google.com` has been visited) cannot be discovered on Android.
  Future<List<Cookie>> getAllCookies({List<Uri>? candidateUrls}) async {
    if (hostIsIOS || hostIsMacOS) {
      return _manager.getAllCookies();
    }
    if (candidateUrls == null || candidateUrls.isEmpty) return [];
    final seen = <String>{};
    final out = <Cookie>[];
    for (final url in candidateUrls) {
      final cookies = await getCookies(url: url);
      for (final c in cookies) {
        final key = '${c.name}|${c.domain ?? ''}|${c.path ?? ''}';
        if (seen.add(key)) out.add(c);
      }
    }
    return out;
  }

  Future<void> setCookie({
    required Uri url,
    required String name,
    required String value,
    String? domain,
    String? path,
    int? expiresDate,
    bool? isSecure,
    bool? isHttpOnly,
  }) async {
    if (value.isEmpty) return;
    await _manager.setCookie(
      url: inapp.WebUri(url.toString()),
      name: name,
      value: value,
      domain: domain,
      path: path ?? '/',
      expiresDate: expiresDate,
      isSecure: isSecure,
      isHttpOnly: isHttpOnly,
    );
  }

  Future<void> deleteCookie({
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) => _manager.deleteCookie(
    url: inapp.WebUri(url.toString()),
    name: name,
    domain: domain,
    path: path ?? '/',
  );

  /// Delete all cookies for a URL.
  /// Used for per-site cookie isolation when switching between same-domain sites.
  Future<void> deleteAllCookiesForUrl(Uri url) async {
    final cookies = await getCookies(url: url);
    for (final cookie in cookies) {
      await deleteCookie(
        url: url,
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path,
      );
    }
  }

  /// Delete ALL cookies from all domains.
  /// Used for aggressive cookie isolation when switching between same-domain sites.
  Future<void> deleteAllCookies() async {
    await _manager.deleteAllCookies();
  }

  /// Commit pending cookie writes to persistent storage.
  ///
  /// Android only: the fork implements `flush` there (fanning out across every
  /// container's jar, not just the default one), and the platform interface's
  /// default throws `UnimplementedError` everywhere else. Callers gate on
  /// [flushSupported] rather than calling and catching, so an unsupported
  /// platform costs no channel round-trip. Failures are swallowed: a flush is
  /// an optimization over the platform's own lazy commit, never a correctness
  /// requirement.
  static bool get flushSupported => hostIsAndroid;

  Future<void> flush() async {
    if (!flushSupported) return;
    try {
      await _manager.flush();
    } catch (e) {
      LogService.instance.log(
        'CookieManager',
        'flush() failed: $e',
        level: LogLevel.warning,
      );
    }
  }
}

/// Find matches result
class FindMatchesResult {
  int activeMatchOrdinal = 0;
  int numberOfMatches = 0;
}

/// Theme preference for webviews
enum WebViewTheme { light, dark, system }

/// Answer the loopback proxy router's `407` with this site's credential
/// (PROXY-013).
///
/// Chromium routes a proxy auth challenge to the `WebContents` that
/// issued the request, so this callback is the one per-WebView channel
/// Android gives us for saying *which site* a connection belongs to.
///
/// [identity] is the site's routing identity, not always its site id: a
/// site with no container profile shares one identity with every other
/// such site, because they share the network session whose auth cache
/// holds the credential ([routerIdentityForSite]).
///
/// Returns null for anything that is not the relay's challenge, which is
/// the platform's own default (cancel). That matters: Android's callback
/// drops `is_proxy` and the port, so a site serving its own `401` lands
/// here too, and proceeding would hand the page a token that admits its
/// bearer to every site's route.
///
/// Where router mode is not active, [ProxyRouterService.ownsChallenge] is
/// false and this returns null.
Future<inapp.HttpAuthResponse?> answerProxyRouterChallenge(
  String? identity,
  inapp.HttpAuthenticationChallenge challenge,
) async {
  if (identity == null) return null;
  final router = ProxyRouterService.instance;
  final space = challenge.protectionSpace;
  if (!router.ownsChallenge(host: space.host, realm: space.realm)) return null;
  final token = router.tokenFor(identity);
  if (token == null) return null;
  return inapp.HttpAuthResponse(
    action: inapp.HttpAuthResponseAction.PROCEED,
    username: router.usernameFor(identity),
    password: token,
    // Never write the token to the platform's credential store: it is
    // valid only for this run of the relay.
    permanentPersistence: false,
  );
}

/// Answer a webview's `onReceivedHttpAuthRequest`: the proxy router's
/// challenge first, then the site's own (HTTPAUTH-001).
///
/// Order is the security property. Android cannot say whether a challenge
/// came from a proxy, so the relay's `407` and a site's `401` arrive here
/// alike; the router claims its own by bound loopback host and per-run realm
/// nonce, and only what it does not claim reaches [session]. A router-owned
/// challenge is never shown to the user and never answered from saved
/// credentials, whatever [session] would say.
Future<inapp.HttpAuthResponse?> answerHttpAuthChallenge({
  required String? routerIdentity,
  required HttpAuthSession? session,
  required inapp.HttpAuthenticationChallenge challenge,
}) async {
  final space = challenge.protectionSpace;
  if (ProxyRouterService.instance
      .ownsChallenge(host: space.host, realm: space.realm)) {
    return answerProxyRouterChallenge(routerIdentity, challenge);
  }
  if (session == null) return null;
  final HttpAuthCredential? credential;
  try {
    credential = await session.answer(HttpAuthChallengeInfo(
      host: space.host,
      realm: space.realm,
      isProxy: space.proxyType != null,
      // Android's count is one static shared by every webview in the
      // process, and it already reads 1 on a first challenge.
      platformRetry: !hostIsAndroid && challenge.previousFailureCount > 0,
    ));
  } catch (e) {
    LogService.instance.log(
      'HttpAuth',
      'Challenge from ${space.host} not answered: $e',
      level: LogLevel.error,
      sensitivity: LogSensitivity.sensitive,
    );
    return null;
  }
  if (credential == null) return null;
  return inapp.HttpAuthResponse(
    action: inapp.HttpAuthResponseAction.PROCEED,
    username: credential.username,
    password: credential.password,
    // The platform's store is app-wide; saving is HttpAuthSecureStorage's
    // job, per site (HTTPAUTH-004).
    permanentPersistence: false,
  );
}

HttpAuthSession _httpAuthSessionFor(WebViewConfig config) => HttpAuthSession(
      siteId: config.posture.siteId,
      siteUrl: config.initialUrl,
      memory: config.posture.container.httpAuthMemory,
      store: HttpAuthSecureStorage.instance,
      prompt: config.hooks.httpAuth,
    );

void _logSiteIcon(String message) =>
    LogService.instance.log('SiteIcon', message);

/// Whether the site's own blockers let a request for one of its page icons
/// through: the DNS level and filter lists its webview applies to an image
/// the page loads (ICON-013).
bool _pageIconRequestAllowed(
  WebViewConfig config,
  Uri target,
  String documentUrl, {
  String requestType = 'image',
}) =>
    _verdictFor(
      config,
      UrlQuery(target.toString(),
          sourceUrl: documentUrl, requestType: requestType),
    ) is Allowed;

final class _LiveBlockLists implements BlockLists {
  const _LiveBlockLists();

  @override
  bool dnsBlocksUrl(String url, int level) =>
      DnsBlockService.instance.isBlockedAtLevel(url, level);

  @override
  bool dnsBlocksHost(String host, int level) =>
      DnsBlockService.instance.isHostBlockedAtLevel(host, level);

  @override
  bool abpBlocksUrl(String url,
          {required String sourceUrl, required String requestType}) =>
      ContentBlockerService.instance
          .isBlocked(url, sourceUrl: sourceUrl, requestType: requestType);

  @override
  bool abpBlocksHost(String host) =>
      ContentBlockerService.instance.isHostBlocked(host);

  @override
  String? abpRedirect(String url,
          {required String sourceUrl, required String requestType}) =>
      ContentBlockerService.instance
          .redirectFor(url, sourceUrl: sourceUrl, requestType: requestType);
}

BlockVerdict _verdictFor(WebViewConfig config, BlockQuery query) =>
    BlockDecision.decide(query, config.blockPolicy, const _LiveBlockLists());

/// [_verdictFor], counted in the site's block stats.
BlockVerdict _judgeAndRecord(WebViewConfig config, BlockQuery query) {
  final verdict = _verdictFor(config, query);
  DnsBlockService.instance
      .recordVerdict(config.posture.siteId, query, verdict);
  return verdict;
}

/// The identity a site presents to the proxy router (PROXY-013).
///
/// Sites without a container profile share the default profile's cached
/// proxy credential, so they share one identity; see
/// [ProxyRouterEngine.sharedProfileIdentity].
String routerIdentityForSite({
  required String siteId,
  String? archiveContainerId,
  required bool incognito,
}) =>
    ProxyRouterEngine.identityFor(
      siteId: siteId,
      ownsContainer: siteOwnsContainerProfile(
        containersSupported: ContainerNative.instance.cachedSupported,
        containerSiteIdentifier: archiveContainerId ?? siteId,
        incognito: incognito,
      ),
    );

String _routerIdentityForConfig(WebViewConfig config) => routerIdentityForSite(
      siteId: config.posture.siteId,
      archiveContainerId: config.posture.container.archiveContainerId,
      incognito: config.posture.container.incognito,
    );

/// Whether a site gets a native container profile of its own.
///
/// The single source for the binding rule, because three other decisions
/// have to agree with it: which routing identity the site presents to the
/// proxy router, whether router mode still has to serialise it, and which
/// profile the PROXY-015 probe measures. A site that is bound here has its
/// own Chromium network session, and therefore its own cached proxy
/// credential; one that is not shares the default profile with every other
/// such site.
bool siteOwnsContainerProfile({
  required bool containersSupported,
  required String? containerSiteIdentifier,
  required bool incognito,
}) =>
    containersSupported &&
    containerSiteIdentifier != null &&
    // Android binds one even under incognito: it has no ephemeral profile,
    // so an unbound site would share the default store with every other
    // such site and leave its storage behind (ARCH-006/ARCH-007). The other
    // platforms short-circuit to an ephemeral store instead, which is a
    // session of its own and needs no name.
    (!incognito || hostIsAndroid);

/// The native container a site's webview binds (`ws-<id>`), or null when it
/// binds none: the legacy engine, or an incognito site off Android, which gets
/// an ephemeral store. [archiveContainerId] stands in for [siteId] for an
/// archive-tier site. The one rule [WebViewFactory.createWebView] binds by and
/// the site info sheet reports.
String? containerIdFor({
  required String? siteId,
  String? archiveContainerId,
  required bool incognito,
}) {
  final containerSiteIdentifier = archiveContainerId ?? siteId;
  return siteOwnsContainerProfile(
    containersSupported: ContainerNative.instance.cachedSupported,
    containerSiteIdentifier: containerSiteIdentifier,
    incognito: incognito,
  )
      ? 'ws-$containerSiteIdentifier'
      : null;
}

/// Proxy manager singleton.
///
/// Two delivery paths coexist behind a single API:
///
///   * **Android.** Routes through `inapp.ProxyController` — a process-wide
///     singleton override (`PROXY_OVERRIDE` WebViewFeature). Per-site config
///     in the data model is fictional under container mode: with multiple
///     same-base-domain sites loaded concurrently, the last applied proxy
///     wins for every WebView. See PROXY-008. Credentialed upstreams cannot
///     be expressed to `ProxyController` (Chromium rejects userinfo in a
///     proxy rule), so they are fronted by a native loopback relay
///     ([`ProxyRelay`]) that injects the credentials; WebView points at
///     `127.0.0.1:<ephemeral>` with none. See PROXY-010.
///   * **iOS 17+ / macOS 14+.** Genuine per-site proxy via
///     `WKWebsiteDataStore.proxyConfigurations` on the per-container data
///     store, created by the WebSpace fork's `preWKWebViewConfiguration`
///     hook. The proxy ships with [`inapp.InAppWebViewSettings.proxySettings`]
///     at WebView construction; the only call this class makes there is
///     [releaseContainerProxy], which clears a container's proxy by name.
class ProxyManager {
  static final ProxyManager _instance = ProxyManager._internal();
  factory ProxyManager() => _instance;
  ProxyManager._internal();

  /// Whether the process-global Android/Linux override currently names a
  /// proxy. Read by `deferInitialLoadForProxy` so a DEFAULT site built while
  /// another site's proxy is still in force does not issue its first request
  /// through it.
  static bool overrideActive = false;

  /// The process-wide proxy state with no address in it, so a failed load
  /// can say whether a proxy was in its path without a sensitive entry.
  static String get stateForLogs => 'proxyOverride=$overrideActive '
      'router=${ProxyRouterService.instance.isActive}';

  static ProxyBinding? _binding;

  /// Where this process enforces a per-site proxy (PROXY-027).
  ///
  /// Latched on first read, so a WebView built under one binding cannot be
  /// driven by the other for the rest of the run.
  static ProxyBinding get binding => _binding ??= ProxyBindingEngine.bindingWhen(
        isIOS: hostIsIOS,
        isMacOS: hostIsMacOS,
      );

  /// Tests only.
  static void setBindingForTest(ProxyBinding? value) => _binding = value;

  /// Containers this process built a WebView on with a proxy (PROXY-029).
  static final ContainerProxyLedger containerProxies = ContainerProxyLedger();

  /// Called wherever a WebView is built with [proxy] on [containerId].
  static void noteStoreProxy(String? containerId, inapp.ProxySettings? proxy) =>
      containerProxies.noteBuild(containerId, proxy);

  /// Clear [containerId]'s proxy through `ProxyController`, which hands its
  /// WebViews back to the app-wide override or to no proxy. Throws if the
  /// clear fails; the caller keeps the page blank rather than loading it
  /// through the proxy the site gave up.
  Future<void> releaseContainerProxy(String containerId) async {
    await containerProxies.release(
      containerId,
      (id) => inapp.ProxyController.instance().clearProxyOverride(containerId: id),
    );
    LogService.instance.log(
      'Proxy',
      'Cleared container proxy for $containerId',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
  }

  /// [siteId] is the isolation tag a TOR proxy carries (TOR-003): without
  /// it every Tor site would present the app-global credential, and the one
  /// rule in force would put them all on one circuit.
  Future<void> setProxySettings(UserProxySettings settings,
      {String? siteId}) async {
    if (!PlatformInfo.isProxySupported) {
      LogService.instance.log(
        'Proxy',
        'setProxySettings: platform does not support proxy override; no-op',
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }

    // Under the per-store binding the proxy travels through the fork's
    // `inapp.InAppWebViewSettings.proxySettings` field at WebView
    // construction, so there is nothing to flip here —
    // `inapp.ProxyController` is Android-only. Runtime updates of the
    // per-site proxy require the WebView to be rebuilt by the caller (see
    // [WebViewModel.updateProxySettings]).
    if (binding == ProxyBinding.perSite) {
      LogService.instance.log(
        'Proxy',
        'setProxySettings: iOS/macOS bind proxy at WebView construction; no-op here',
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }

    // Router mode owns the process-wide rule: it already points at the
    // loopback router for every site, and flipping it per activation is
    // exactly the serialisation PROXY-013 removes. Per-site routing is
    // refreshed through `ProxyRouterService`, not here.
    if (ProxyRouterService.instance.isActive) {
      LogService.instance.log(
        'Proxy',
        'setProxySettings: router mode active; process-wide rule unchanged',
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }

    final controller = inapp.ProxyController.instance();

    // When the per-site setting is DEFAULT, fall through to the app-global
    // outbound proxy. This keeps webview traffic and Dart-side traffic
    // honoring the same proxy precedence: explicit per-site override wins,
    // otherwise the global applies, otherwise system/direct.
    var effective = resolveEffectiveProxy(settings, siteId: siteId);
    final fellThrough = settings.type == ProxyType.DEFAULT &&
        effective.type != ProxyType.DEFAULT;
    // TOR names no address of its own; the rule has to carry the endpoint
    // the runtime serves and this site's credential, or the leftover manual
    // address a TOR setting keeps (PROXY-010) would be dialled in clear.
    if (effective.type == ProxyType.TOR) {
      final expanded = expandTorProxy(effective);
      if (expanded == null) {
        LogService.instance.log(
          'Proxy',
          'Tor is not up; refusing to apply a proxy rule for a Tor site.',
          level: LogLevel.error,
          sensitivity: LogSensitivity.sensitive,
        );
        throw Exception('Tor is not up');
      }
      effective = expanded;
    }

    if (effective.type == ProxyType.DEFAULT) {
      if (hostIsAndroid) await ProxyRelay.instance.stop();
      LogService.instance.log(
        'Proxy',
        'Clearing proxy override (per-site=DEFAULT, no global proxy set)',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
      final sw = Stopwatch()..start();
      await controller.clearProxyOverride();
      overrideActive = false;
      LogService.instance.log(
        'Proxy',
        'Cleared proxy override (native call took ${sw.elapsedMilliseconds}ms)',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }

    if (effective.address == null || effective.address!.isEmpty) {
      LogService.instance.log(
        'Proxy',
        'Effective proxy missing address; aborting setProxyOverride. '
            'Effective: ${effective.describeForLogs()}',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      throw Exception('Proxy address is required');
    }

    final parts = effective.address!.split(':');
    if (parts.length != 2) {
      LogService.instance.log(
        'Proxy',
        'Effective proxy address malformed (expected host:port). '
            'Effective: ${effective.describeForLogs()}',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      throw Exception('Proxy address must be in format host:port');
    }

    final host = parts[0];
    final port = int.tryParse(parts[1]);
    if (port == null) {
      LogService.instance.log(
        'Proxy',
        'Effective proxy port is not numeric. '
            'Effective: ${effective.describeForLogs()}',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      throw Exception('Invalid port number');
    }

    final scheme = switch (effective.type) {
      ProxyType.HTTPS => 'https',
      ProxyType.SOCKS5 => 'socks5',
      _ => 'http',
    };

    // Android's ProxyController has no proxy-auth primitive: a rule with
    // embedded `user:pass@` userinfo is rejected by Chromium and the
    // WebView silently goes direct (leaking the real IP). Route a
    // credentialed upstream through the native loopback relay and point
    // WebView at it with NO credentials; the relay injects them upstream.
    // iOS/macOS never reach here; Linux/WebKit accepts a credentialed
    // proxy URI directly, so it keeps the inline-credential path below.
    if (hostIsAndroid && effective.hasCredentials) {
      final relay = await ProxyRelay.instance.start(effective);
      if (relay == null) {
        LogService.instance.log(
          'Proxy',
          'Auth proxy relay failed to start; refusing to fall back to a '
              'direct connection. Effective: ${effective.describeForLogs()}',
          level: LogLevel.error,
          sensitivity: LogSensitivity.sensitive,
        );
        throw Exception('Proxy relay failed to start');
      }
      LogService.instance.log(
        'Proxy',
        'Applying Android proxy override via auth relay (upstream scheme=$scheme'
            '${fellThrough ? ', via DEFAULT->global fallthrough' : ''}, '
            'effective: ${effective.describeForLogs()})',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
      final sw = Stopwatch()..start();
      await controller.setProxyOverride(
        settings: inapp.ProxySettings(
          proxyRules: [inapp.ProxyRule(url: 'http://${relay.host}:${relay.port}')],
          // No `<local>`: it exempts dotless hosts (http://intranet/) from
          // the proxy entirely, and the coverage contract is every byte.
          // Loopback is bypassed by Chromium regardless, which is what
          // keeps the relay itself reachable.
          bypassRules: [],
        ),
      );
      overrideActive = true;
      LogService.instance.log(
        'Proxy',
        'Applied proxy override via relay (native call took ${sw.elapsedMilliseconds}ms, '
            'relay endpoint=${relay.host}:${relay.port})',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }

    // No credentials (or Linux): point ProxyController straight at the
    // upstream. Stop any relay left over from a previous credentialed
    // config so its loopback port isn't left listening.
    if (hostIsAndroid) await ProxyRelay.instance.stop();

    final proxyUrl = effective.hasCredentials
        ? '$scheme://${Uri.encodeComponent(effective.username!)}:${Uri.encodeComponent(effective.password!)}@$host:$port'
        : '$scheme://$host:$port';

    LogService.instance.log(
      'Proxy',
      'Applying proxy override (scheme=$scheme'
          '${fellThrough ? ', via DEFAULT->global fallthrough' : ''}, '
          'effective: ${effective.describeForLogs()})',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
    final sw = Stopwatch()..start();
    await controller.setProxyOverride(
      settings: inapp.ProxySettings(
        proxyRules: [inapp.ProxyRule(url: proxyUrl)],
        bypassRules: [],
      ),
    );
    overrideActive = true;
    LogService.instance.log(
      'Proxy',
      'Applied proxy override (native call took ${sw.elapsedMilliseconds}ms, '
          'scheme=$scheme)',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
  }

  /// Point the process-wide rule at the loopback router on [host]:[port]
  /// and leave it there (PROXY-013). The host is the random 127/8 address
  /// the relay bound, not `127.0.0.1`.
  ///
  /// Returns false if the override could not be applied, in which case
  /// the caller MUST NOT treat router mode as active — every site would
  /// otherwise go direct while believing it was proxied.
  Future<bool> applyRouterOverride(String host, int port) async {
    if (!hostIsAndroid || !PlatformInfo.isProxySupported) return false;
    try {
      await inapp.ProxyController.instance().setProxyOverride(
        settings: inapp.ProxySettings(
          proxyRules: [inapp.ProxyRule(url: 'http://$host:$port')],
          bypassRules: [],
        ),
      );
      LogService.instance.log(
        'Proxy',
        'Applied router override -> $host:$port',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
      return true;
    } catch (e) {
      LogService.instance.log(
        'Proxy',
        'Router override failed to apply: $e',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      return false;
    }
  }

  Future<void> clearProxy() async {
    if (!PlatformInfo.isProxySupported) return;
    // Nothing process-wide to clear when each store carries its own rule.
    if (binding == ProxyBinding.perSite) return;
    if (hostIsAndroid) await ProxyRelay.instance.stop();
    final sw = Stopwatch()..start();
    await inapp.ProxyController.instance().clearProxyOverride();
    overrideActive = false;
    LogService.instance.log(
      'Proxy',
      'Cleared proxy override via clearProxy() (native call took ${sw.elapsedMilliseconds}ms)',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
  }
}

/// Platform info - proxy support detection.
///
/// Returns true on:
/// - Android, when the System WebView reports `PROXY_OVERRIDE` support.
/// - iOS / macOS, unconditionally — the fork's
///   `preWKWebViewConfiguration` gates internally on iOS 17+ / macOS 14+.
///   Below that floor, the per-site proxy block silently no-ops and the
///   site uses system default routing (matches `ProxyType.DEFAULT`).
/// - Linux, unconditionally — the fork's `flutter_inappwebview_linux`
///   ProxyManager calls `webkit_network_session_set_proxy_settings` on
///   the active session. WebKitGTK / WPE has shipped the proxy API
///   since 2.26; the fork builds against ≥ 2.40 (matching our pubspec
///   override floor) so no runtime feature probe is needed.
class PlatformInfo {
  static bool? _isProxySupportedCached;

  static Future<void> initialize() async {
    if (hostIsIOS || hostIsMacOS) {
      // The fork writes the per-site proxy onto
      // `WKWebsiteDataStore.proxyConfigurations`, which is
      // `@available(iOS 17.0, macOS 14.0, *)`. Below the floor the field is
      // ignored and the site would load over the device IP (LEAK-003), so
      // report no support: the row is hidden and `_bindingFor` fails closed.
      _isProxySupportedCached =
          appleOsMeetsFloor(hostOperatingSystemVersion, isIOS: hostIsIOS);
      return;
    }
    if (hostIsLinux) {
      // The fork's ProxyController binds via
      // `webkit_network_session_set_proxy_settings`, available on every
      // WebKitGTK / WPE build we support.
      _isProxySupportedCached = true;
      return;
    }
    try {
      _isProxySupportedCached = await inapp.WebViewFeature.isFeatureSupported(
        inapp.WebViewFeature.PROXY_OVERRIDE,
      );
    } catch (e) {
      _isProxySupportedCached = false;
    }
  }

  static bool get isProxySupported => _isProxySupportedCached ?? false;
}

/// Configuration for creating a webview
class WebViewConfig {
  /// Unique key to force widget recreation when settings change.
  /// When this key changes, Flutter will create a new widget state.
  final Key? key;
  /// What every webview that runs as the site applies, resolved once by
  /// `WebViewModel.sitePosture`. A popup this webview spawns inherits it.
  final SitePosture posture;
  final String initialUrl;
  /// iOS/macOS only: enable WKWebView's native back/forward swipe gesture
  /// (`allowsBackForwardNavigationGestures`). Set only for the root site
  /// webview, which lives at the `MaterialApp` root route where no Flutter
  /// route-pop edge-swipe exists — so without this Apple has no reliable
  /// back-swipe in the main view (the `PopScope` handler only fires for
  /// pushable routes). Nested `InAppWebViewScreen`s leave this false: they
  /// are pushed routes whose own PopScope navigates webview-back and pops
  /// the route at history start (NAV-008), which the native gesture would
  /// otherwise hijack. No effect on Android.
  final bool backForwardGestures;
  /// Android only: build the webview with no initial load (neither
  /// `initialUrlRequest` nor cached-HTML `initialData`) so the
  /// controller-created handler can apply `restoreState` to a pristine
  /// back/forward list. Android's `WebView.restoreState` is dropped when the
  /// WebView has already navigated — its docs warn that calling it after the
  /// view "had a chance to build state (load pages, create a back/forward
  /// list, etc.) there may be undesirable side-effects". The handler reloads
  /// the restored top entry afterward, since Android does not restore display
  /// data. iOS/macOS replace state in place via `WKWebView.interactionState`,
  /// so they keep the initial load and leave this false.
  final bool deferInitialLoad;
  /// BGAUDIO-006: inject the media-session bridge shim + register the
  /// `wsMediaSession` handler so this site's playback drives the Android
  /// foreground media notification. Android-only effect. Set only by the
  /// site's own webview, from the slot's setting rather than the posture:
  /// the background-audio lifecycle belongs to the slot, whatever site a
  /// hosted tab runs as.
  final bool backgroundAudioEnabled;
  final Function(String url)? onUrlChanged;
  final Function(List<Cookie> cookies)? onCookiesChanged;
  final Function(int activeMatch, int totalMatches)? onFindResult;
  final Function(String url, bool hasGesture)? shouldOverrideUrlLoading;
  /// Fires when a main-frame navigation was cancelled because the app could
  /// not establish that it would go through this site's proxy (LEAK-010).
  /// Carries the destination that was not requested, so the host can render
  /// the interstitial that says so.
  final void Function(String url)? onUnproxiedNavigationBlocked;
  /// Fires when the page enters or exits a loading state. Driven by
  /// `onLoadStart` (true) and `onLoadStop` (false). The call site can
  /// use this to swap a Refresh button with a Stop button while a
  /// navigation is in flight.
  final Function(bool isLoading)? onLoadingChanged;
  /// Fires when this webview reloads itself (the cached-HTML one-shot live
  /// refresh below). A reload discards the painted frame and recommits it
  /// later, so on Android the hybrid-composition surface sits blank in
  /// between with nothing to relayout it (BUG-001 / PAUSE-021). Host-driven
  /// reloads funnel through `WebViewModel.reloadAndRepaint`; this is the
  /// same signal for the ones the factory issues on its own.
  final VoidCallback? onReloadIssued;
  /// Fires on every main-frame load lifecycle transition (start / settle /
  /// failure). Feeds `ResumeReloadEngine`, which decides whether a load the
  /// OS stranded while the app was backgrounded has to be re-issued on the
  /// next resume (PAUSE-022). Distinct from [onLoadingChanged], which is
  /// UI state and carries neither the URL nor the failure.
  final void Function(MainFrameLoadSignal signal)? onMainFrameLoad;
  /// Fires as the main-frame load advances, with progress in 0-100.
  /// Driven by the platform's `onProgressChanged`. The call site can
  /// use this to render a determinate loading bar while a navigation
  /// is in flight ([onLoadingChanged] gates visibility).
  final Function(int progress)? onProgressChanged;
  /// Callback when page HTML should be cached. Called on page load with (url, html).
  final Function(String url, String html)? onHtmlLoaded;
  /// Optional pre-gate for the [onHtmlLoaded] path. Returning `false`
  /// makes `onLoadStop` skip the [htmlSnapshotScript] IPC entirely
  /// (not just the encrypt+write that follows). The IPC is the
  /// expensive, lifecycle-racing piece — the renderer has to walk and
  /// serialize the live DOM, and during a frame teardown that walk
  /// can hold a `raw_ptr` to a soon-to-be-freed Frame. Skipping the
  /// IPC outright is the only way to drop the renderer pressure.
  /// When unset, every `onLoadStop` fetches HTML (legacy behavior).
  final bool Function()? shouldFetchHtml;
  /// Optional cached HTML to display when offline. Sub-resources (CSS/JS/images)
  /// load from the browser's HTTP cache via LOAD_CACHE_ELSE_NETWORK mode.
  final String? initialHtml;
  /// Severity level every DNS check for this site runs at: 0 when the toggle
  /// is off, otherwise the resolved per-site level, which falls back to the
  /// app-wide one until its list is downloaded. One number so the toggle and
  /// the level can't disagree at a call site.
  int get effectiveDnsLevel => posture.blocking.dns
      ? DnsBlockService.instance.effectiveLevelFor(posture.blocking.dnsLevel)
      : kDnsLevelOff;
  BlockPolicy get blockPolicy => (
        dnsLevel: effectiveDnsLevel,
        contentBlock: posture.blocking.contentBlock,
      );
  /// Callback for JS console messages.
  final Function(String message, inapp.ConsoleMessageLevel level)? onConsoleMessage;
  /// The host's answers for every webview that runs as the site: prompts,
  /// popups, external schemes and the cookie readers.
  final WebViewHostHooks hooks;
  /// A long-press that landed on a link (`SRC_ANCHOR_TYPE`). The host opens
  /// its link menu, whose "Open in new tab" is how a child tab is created
  /// (TAB-006). Android and iOS only: the plugin backs this with
  /// `View.setOnLongClickListener` / `UILongPressGestureRecognizer`, and there
  /// is no macOS or Linux equivalent, so those platforms reach the same
  /// actions from the tab list instead.
  final void Function(String url)? onLinkLongPress;
  /// Pull-to-refresh, with the gate that keeps a pinch from firing it
  /// (NAV-006); the factory feeds it from a [Listener] around the webview.
  final PullToRefreshGate? pullToRefreshGate;
  /// Fires when the underlying renderer terminates unexpectedly. On Android
  /// this maps to `WebView.onRenderProcessGone` — the OS sometimes kills the
  /// renderer to reclaim memory after the app has been backgrounded for a
  /// while, leaving the WebView's surface in an unusable "black screen"
  /// state until it's destroyed and recreated. The host is expected to drop
  /// the controller and rebuild the widget. If unset, the WebView is left
  /// in its post-crash state (visible to the user as a black rectangle).
  final void Function(bool didCrash)? onRendererGone;
  /// Android: the WebView has committed a frame that is visible for the first
  /// time on this navigation. The only signal in the app that fires *because
  /// pixels exist* — every other repaint trigger is a lifecycle event hoped to
  /// imply one, and BUG-001 gap #18 caught a load whose nudges had all drained
  /// twelve seconds before the renderer produced anything.
  final VoidCallback? onPageCommitVisible;
  /// Camera, microphone, screen-sharing and protected-content decisions for
  /// this webview's pages. Null installs none of the capture shims or their
  /// handlers, and leaves permission requests to the platform's default.
  final GrantStore? grants;
  /// Where the page's own icon goes (ICON-009). Set only for the site's root
  /// webview: a nested screen or popup shows another page, often on another
  /// host, and must not repaint the site's icon. Android is the only platform
  /// that reports icons; elsewhere the watcher runs and nothing arrives.
  final SiteIconTarget? siteIcon;
  /// Where the search the site's pages declare goes (LIR-035). Set only for
  /// the site's root webview, and only for a site that has to learn its
  /// search that way.
  final SiteSearchTarget? siteSearch;
  /// Passkeys for this webview's pages (PASSKEY-001). Null leaves WebAuthn
  /// off, which is the WebView's default: no shim, no handler, and the
  /// engine's own `navigator.credentials` refuses a `publicKey` request.
  final PasskeyAccess? passkeys;

  WebViewConfig({
    this.key,
    required this.posture,
    required this.hooks,
    required this.initialUrl,
    this.backForwardGestures = false,
    this.deferInitialLoad = false,
    this.backgroundAudioEnabled = false,
    this.onUrlChanged,
    this.onLoadingChanged,
    this.onReloadIssued,
    this.onMainFrameLoad,
    this.onProgressChanged,
    this.onCookiesChanged,
    this.onFindResult,
    this.shouldOverrideUrlLoading,
    this.onUnproxiedNavigationBlocked,
    this.onHtmlLoaded,
    this.shouldFetchHtml,
    this.initialHtml,
    this.onConsoleMessage,
    this.onLinkLongPress,
    this.pullToRefreshGate,
    this.onRendererGone,
    this.onPageCommitVisible,
    this.grants,
    this.siteIcon,
    this.siteSearch,
    this.passkeys,
  });
}

/// Controller interface for webview operations
abstract class WebViewController {
  /// The underlying `inapp.InAppWebViewController` this wrapper is
  /// bound to. Exposed so per-site code paths can pass it as the
  /// `webViewController:` argument to `inapp.CookieManager` methods,
  /// which the WebSpace fork uses to resolve the WebView's bound
  /// container and route cookie ops to its per-container jar.
  inapp.InAppWebViewController get nativeController;

  Future<void> loadUrl(String url, {String? language});
  /// False when no load starts: the webview is gone or the platform refused.
  Future<bool> reload();
  Future<Uri?> getUrl();
  Future<String?> getTitle();
  Future<String?> getHtml();
  Future<void> evaluateJavascript(String source);
  /// Evaluate [source] and return whatever the JS expression produced,
  /// JSON-decoded by the platform plugin into a Dart `dynamic`.
  /// Distinct from
  /// [evaluateJavascript] which suffixes the source with `null;` to
  /// neutralize WebKit's "unsupported return type" errors and so
  /// always resolves to `null`.
  Future<Object?> evaluateJavascriptReturning(String source);
  Future<void> findAllAsync({required String find});
  Future<void> findNext({required bool forward});
  Future<void> clearMatches();
  Future<String?> getDefaultUserAgent();
  Future<void> setOptions({
    required bool javascriptEnabled,
    String? userAgent,
    bool? thirdPartyCookiesEnabled,
    bool? incognito,
  });
  Future<void> setThemePreference(WebViewTheme theme);
  /// Update the page-text zoom (percent, 100 = unscaled). Used to track
  /// system "font size" accessibility changes after the webview is created.
  Future<void> setTextZoom(int zoomPercent);
  Future<void> goBack();
  Future<bool> canGoBack();
  /// Per-instance pause to reduce resource usage.
  ///
  /// On Android: **no-op.** `WebView.onPause()` only does a best-effort pause
  /// of animations and geolocation and **does NOT pause JavaScript** (Android
  /// pauses JS only via the process-global `pauseTimers()`), so per-instance
  /// pause is nearly useless — while cycling the foreground hybrid-composition
  /// SurfaceView through onPause/onResume blanks it on the next paint. JS is
  /// frozen at app-background via [pauseAllJsTimers]; memory pressure disposes.
  ///
  /// On iOS: calls `pauseTimers()`, which the plugin implements per-instance
  /// via an `alert()`-deadlock hack that blocks this WebView's main JS thread.
  ///
  /// Activity that keeps running while paused on **both** platforms:
  ///   - Web Workers and Service Workers
  ///   - network requests already in flight (and any `Set-Cookie` they return)
  ///   - media playback (`<video>` / `<audio>` decoders)
  ///   - WebRTC peer connections, WebSocket frames over the wire
  ///
  /// `pause()` is for resource saving. It is **not a security boundary** — a
  /// page can observe cookies being deleted or proxy being swapped while
  /// paused (e.g. via a Service Worker fetch, or via `document.cookie` diff
  /// on the next `visibilitychange`). To safely mutate global state under
  /// a webview, dispose it instead.
  Future<void> pause();

  /// Resume a previously paused webview.
  Future<void> resume();

  /// Pause JavaScript timers (`setTimeout`/`setInterval`/`requestAnimationFrame`)
  /// process-globally on Android, per-instance on iOS.
  ///
  /// On Android, `WebView.pauseTimers()` is documented as global across all
  /// loaded WebViews. Use this only when the whole app is going to background;
  /// do **not** use it to pause a single site, otherwise you also freeze the
  /// site that's about to become active.
  Future<void> pauseAllJsTimers();

  /// Inverse of [pauseAllJsTimers].
  Future<void> resumeAllJsTimers();

  /// Abort any in-flight main-frame load. Used to quiesce chromium
  /// before queuing a follow-up navigation, shrinking the overlap
  /// between in-flight teardown and the next loadUrl.
  Future<void> stopLoading();

  /// Drop the WebView's in-memory cache (decoded image cache + the
  /// HTTP response cache). Tab state stays — the page keeps running,
  /// the back/forward stack is intact. Idempotent: a second call
  /// is a near no-op (the cache is already empty).
  ///
  /// Used by the [SiteLifecyclePromotionEngine] cacheCleared tier to
  /// reclaim memory under OS pressure without losing tab state. Frees
  /// roughly 10-50 MB per webview depending on what was cached.
  Future<void> clearCache();

  /// Capture the WebView's navigation state into a serializable byte
  /// blob. Pair with [restoreState] on a freshly-created controller
  /// to re-hydrate the back/forward stack and (on iOS 15+ / macOS
  /// 12+) form-field values. Live JS heap and DOM are NOT preserved.
  ///
  /// Returns null when there's nothing to save (e.g. a webview that
  /// never navigated).
  ///
  /// Platform mapping:
  ///   - Android: `WebView.saveState(Bundle)` — back/forward + scroll.
  ///   - iOS 15+ / macOS 12+: `WKWebView.interactionState` — back/
  ///     forward + form-field values + scroll.
  ///   - Linux (WebKitGTK / WPE): `webkit_web_view_get_session_state`
  ///     + `webkit_web_view_session_state_serialize` — back/forward
  ///     + scroll. Form-field values are NOT preserved (Apple-only).
  Future<Uint8List?> saveState();

  /// Apply [state] (previously returned by [saveState] on the same
  /// site) to this controller. Returns true on success.
  Future<bool> restoreState(Uint8List state);
}

/// Which native call the per-instance [WebViewController.pause] /
/// [WebViewController.resume] makes on a given platform (PAUSE-016).
enum PerInstanceLifecycleCall {
  /// No native call. Android (`WebView.onPause()` doesn't freeze JS and
  /// cycling the SurfaceView blanks it — PAUSE-016) and desktop platforms.
  none,

  /// iOS: `pauseTimers()` / `resumeTimers()` — the plugin's per-instance
  /// `alert()`-deadlock hack, the only per-site JS-freeze lever on iOS.
  timers,
}

/// Pure platform dispatch for per-instance pause/resume. Extracted so the
/// PAUSE-016 Android no-op is unit-testable without a native controller.
PerInstanceLifecycleCall perInstanceLifecycleCallFor({
  required bool isAndroid,
  required bool isIOS,
}) {
  if (isAndroid) return PerInstanceLifecycleCall.none;
  if (isIOS) return PerInstanceLifecycleCall.timers;
  return PerInstanceLifecycleCall.none;
}

/// Whether `pauseTimers()` on this platform is the plugin's messageless
/// `alert()` hack rather than a real timer pause. Android has the real API
/// (`WebView.pauseTimers()`); iOS and macOS both implement it by evaluating
/// `alert()` and having the native `WKUIDelegate` withhold its dismissal
/// callback, which is what blocks the page's JS thread.
bool pauseTimersUsesAlertHack({
  required bool isAndroid,
  required bool isIOS,
  required bool isMacOS,
}) =>
    !isAndroid && (isIOS || isMacOS);

/// Per-webview record of whether the `alert()`-hack pause has ever run on it
/// (PAUSE-030), so the hack's own alert can be told apart from a dialog the
/// page asked for.
class PauseTimersHackState {
  bool _issued = false;

  /// True once a `pauseTimers()` that uses the alert hack has been issued on
  /// this webview. Sticky: the hack leaves an alert queued in the page's JS
  /// event loop with no signal for when it was consumed, so there is no point
  /// at which this can be cleared without re-opening the escape.
  bool get pauseWasIssued => _issued;

  void notePauseIssued() => _issued = true;
}

/// Whether a JS alert arriving in Dart is the escaped remains of the
/// `alert()`-hack pause (PAUSE-030) rather than a dialog the page asked for.
///
/// `pauseTimers()` marks the webview paused and evaluates `alert()`; the
/// native delegate swallows that alert for as long as the mark is set.
/// `resumeTimers()` clears the mark on the next site switch, app resume or
/// dispose whether or not the alert has been delivered — and
/// `evaluateJavaScript` queues behind the page's own JS, so on a busy or
/// still-loading page the alert can land after the mark is gone and fall
/// through to the app as a real, messageless system dialog.
///
/// Only an escaped alert can reach this predicate: the native delegate
/// consults Dart only after its own paused check, so while the pause is live
/// the alert never gets here. Answering it therefore releases a JS thread
/// whose pause is already over, rather than cutting one short.
///
/// A page's own main-frame `alert('')` on an already-paused webview is
/// swallowed too. It is indistinguishable from the hack's, and it renders as
/// an empty system dialog carrying no information either way.
bool isEscapedPauseTimersAlert({
  required bool pauseWasIssued,
  required String? message,
  required bool? isMainFrame,
}) =>
    pauseWasIssued && (message ?? '').isEmpty && (isMainFrame ?? true);

/// Whether the root site webview must defer its initial load so the
/// controller-created handler can apply `restoreState` to a pristine
/// back/forward list. True only on Android: `WebView.restoreState` no-ops
/// when the WebView has already navigated (an `initialUrlRequest` would build
/// a 1-entry history first), so the back/forward stack restore is silently
/// dropped. iOS/macOS `WKWebView.interactionState` replaces the stack in
/// place even after a load started, so they keep the initial load.
///
/// Excludes file:// imports: their URL is a synthetic handle with no
/// fetchable form, so the post-restore reload would surface
/// ERR_FILE_NOT_FOUND — and back/forward history is meaningless for a static
/// local page anyway, so they keep rendering their cached `initialData`.
/// Only meaningful when nav-state bytes are actually pending for this build.
/// Android and Linux apply the proxy as a process-global override from Dart
/// after the platform view exists (`WebViewModel.setController`). A site whose
/// effective proxy is non-DEFAULT must therefore carry no initial load, or its
/// first request leaves before the override lands; the same holds for a
/// DEFAULT site while the override still names another site's proxy.
/// `setController` issues the first load once the override is in (LEAK-003).
///
/// Every platform that binds a proxy per container defers too when the
/// container still carries a proxy its site no longer names: the clear goes
/// out from `setController` as well (PROXY-029).
bool deferInitialLoadForProxy({
  required bool proxyIsGlobal,
  required bool effectiveNonDefault,
  required bool overrideActive,
  required bool releasesContainerProxy,
}) =>
    releasesContainerProxy ||
    (proxyIsGlobal && (effectiveNonDefault || overrideActive));

bool deferInitialLoadForRestore({
  required bool hasPendingRestoreState,
  required bool isAndroid,
  required bool isFileImport,
}) =>
    hasPendingRestoreState && isAndroid && !isFileImport;

/// Writes the fields [WebViewController.setOptions] owns onto the settings a
/// webview was created with; every other field keeps its value.
@visibleForTesting
void applyWebViewOptions(
  inapp.InAppWebViewSettings settings, {
  required bool javascriptEnabled,
  String? userAgent,
  bool? thirdPartyCookiesEnabled,
  bool? incognito,
}) {
  settings
    ..javaScriptEnabled = javascriptEnabled
    ..userAgent = userAgent
    // Keep Sec-CH-UA*/navigator.userAgentData consistent with the UA
    // string. Webview recreation on UA edits is the primary path
    // (DM-001), so this is a defensive parallel apply for the rare
    // setSettings-only path.
    ..userAgentMetadata = buildUserAgentMetadata(userAgent)
    ..thirdPartyCookiesEnabled = thirdPartyCookiesEnabled ?? false
    ..incognito = incognito ?? false;
}

/// The [WebViewController] over one native webview. Every native call goes
/// through [_native], so a call on a webview that has left the tree is a
/// no-op and a platform refusal reads as "nothing happened".
class _WebViewController implements WebViewController {
  final inapp.InAppWebViewController _c;

  /// Set by [_ControllerScope] in the frame the plugin disposes [_c]. A call
  /// on a disposed controller asserts in debug and does nothing in release.
  bool _disposed = false;

  /// Shared with the `onJsAlert` handler of the same webview, which needs to
  /// know that this controller issued an alert-hack pause (PAUSE-030).
  final PauseTimersHackState _pauseHack;

  final FileImportDocument? _import;

  /// The settings this webview was created with, kept current by every
  /// update. Each `setSettings` sends this whole object: the plugin sends
  /// every field of what it is given, Android and iOS/macOS apply each one
  /// that differs, and Linux replaces its settings wholesale, so a fresh
  /// object resets whatever it leaves out to the plugin default (BUG-022).
  final inapp.InAppWebViewSettings _settings;

  _WebViewController(
    this._c, {
    required PauseTimersHackState pauseHack,
    required inapp.InAppWebViewSettings settings,
    FileImportDocument? fileImport,
  })  : _pauseHack = pauseHack,
        _settings = settings,
        _import = fileImport;

  /// Null when the webview is gone or the platform refused: a native
  /// failure arrives as [PlatformException], a torn-down platform view as
  /// [MissingPluginException].
  Future<T?> _native<T>(Future<T?> Function() call) async {
    if (_disposed) return null;
    try {
      return await call();
    } on PlatformException catch (e) {
      LogService.instance.log('WebView', 'Native call refused: $e',
          sensitivity: LogSensitivity.sensitive);
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> _issued(Future<void> Function() call) async =>
      await _native(() => call().then((_) => true)) ?? false;

  @override
  inapp.InAppWebViewController get nativeController => _c;

  @override
  Future<void> loadUrl(String url, {String? language}) async {
    final fileImport = _import;
    if (fileImport != null && fileImport.isLoadOf(url)) {
      await _loadHtml(fileImport.html, fileImport.url);
      return;
    }
    final headers = <String, String>{};
    // HTTP headers are only meaningful for http(s) schemes. Attaching them to
    // non-HTTP URLs (chrome://, about:, file://, data:, javascript:) routes
    // the request through the WebView's HTTP path and can get rejected as
    // "invalid URL".
    final isHttp = url.startsWith('http://') || url.startsWith('https://');
    if (isHttp) {
      headers['DNT'] = '1';
      headers['Sec-GPC'] = '1';
    }
    if (language != null && isHttp) {
      headers['Accept-Language'] = '$language, *;q=0.5';
    }
    await _native(() => _c.loadUrl(
          urlRequest: inapp.URLRequest(
            url: inapp.WebUri(url),
            headers: headers.isNotEmpty ? headers : null,
          ),
        ));
  }

  Future<bool> _loadHtml(String html, String baseUrl) =>
      _issued(() => _c.loadData(
            data: html,
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: inapp.WebUri(baseUrl),
          ));

  @override
  Future<bool> reload() {
    final fileImport = _import;
    if (fileImport != null &&
        FileImportDocument.rendersOnReload(isAndroid: hostIsAndroid)) {
      return _loadHtml(fileImport.html, fileImport.url);
    }
    return _issued(() => _c.reload());
  }

  @override
  Future<Uri?> getUrl() => _native(_c.getUrl);

  @override
  Future<String?> getTitle() async => await _native(_c.getTitle);

  @override
  Future<String?> getHtml() async => await _native(_c.getHtml);

  @override
  Future<void> evaluateJavascript(String source) =>
      _native(() => _c.evaluateJavascript(source: '$source\n;null;'));

  @override
  Future<Object?> evaluateJavascriptReturning(String source) =>
      _native(() => _c.evaluateJavascript(source: source));

  @override
  Future<void> findAllAsync({required String find}) =>
      _native(() => _c.findAllAsync(find: find));

  @override
  Future<void> findNext({required bool forward}) =>
      _native(() => _c.findNext(forward: forward));

  @override
  Future<void> clearMatches() => _native(_c.clearMatches);

  @override
  Future<String?> getDefaultUserAgent() async =>
      await _native(inapp.InAppWebViewController.getDefaultUserAgent);

  @override
  Future<void> setOptions({
    required bool javascriptEnabled,
    String? userAgent,
    bool? thirdPartyCookiesEnabled,
    bool? incognito,
  }) {
    applyWebViewOptions(
      _settings,
      javascriptEnabled: javascriptEnabled,
      userAgent: userAgent,
      thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
      incognito: incognito,
    );
    // The OS text size can change between creation and this call, before
    // didChangeTextScaleFactor can reach the controller.
    _settings.textZoom = WebViewFactory.systemTextZoomPercent();
    return _native(() => _c.setSettings(settings: _settings));
  }

  @override
  Future<void> setThemePreference(WebViewTheme theme) async {
    final themeValue = theme == WebViewTheme.system ? 'system' : (theme == WebViewTheme.dark ? 'dark' : 'light');
    // Rotate the DOCUMENT_START user script so future page loads
    // (including controller.reload()) re-run the shim. Without this,
    // a refresh drops the matchMedia override and `<meta name=
    // "color-scheme">` and the page falls back to its own default
    // (typically light), since onUrlChanged dedups same-URL events
    // and skips its own evaluateJavascript reapplication.
    await _rotateShim(
        'theme_color_scheme_shim', buildThemeColorSchemeShim(themeValue));
  }

  @override
  Future<void> setTextZoom(int zoomPercent) async {
    if (hostIsAndroid) {
      _settings.textZoom = zoomPercent;
      await _native(() => _c.setSettings(settings: _settings));
      return;
    }
    // iOS/macOS: WKWebView has no textZoom setting. Rotate the
    // DOCUMENT_START user script so future page loads pick up the new
    // value, then update the style element on the current page.
    await _rotateShim('system_text_zoom', buildTextZoomShim(zoomPercent));
  }

  Future<void> _rotateShim(String group, String shim) async {
    await _native(() => _c.removeUserScriptsByGroupName(groupName: group));
    await _native(() => _c.addUserScript(
        userScript: pageShim(group, shim, frames: ShimFrames.all)));
    await evaluateJavascript(shim);
  }

  @override
  Future<void> goBack() => _native(_c.goBack);

  @override
  Future<bool> canGoBack() async => await _native(_c.canGoBack) ?? false;

  @override
  Future<void> pause() async {
    // PAUSE-016: Android is a no-op. `WebView.onPause()` doesn't pause JS (only
    // the process-global `pauseTimers()` does), so per-instance pause buys
    // nothing for the JS-freeze goal — yet cycling the foreground hybrid-
    // composition SurfaceView through onPause/onResume leaves it blank on the
    // next paint (the white-screen bug). App-lifecycle backgrounding freezes JS
    // via the global `pauseAllJsTimers()`; memory pressure disposes.
    switch (perInstanceLifecycleCallFor(
        isAndroid: hostIsAndroid, isIOS: hostIsIOS)) {
      case PerInstanceLifecycleCall.none:
        return;
      case PerInstanceLifecycleCall.timers:
        _pauseHack.notePauseIssued();
        await _native(_c.pauseTimers);
    }
  }

  @override
  Future<void> resume() async {
    // Mirror of [pause] (PAUSE-016): no-op on Android.
    switch (perInstanceLifecycleCallFor(
        isAndroid: hostIsAndroid, isIOS: hostIsIOS)) {
      case PerInstanceLifecycleCall.none:
        return;
      case PerInstanceLifecycleCall.timers:
        await _native(_c.resumeTimers);
    }
  }

  @override
  Future<void> pauseAllJsTimers() {
    // On iOS and macOS there is no process-global lever: this lands on the
    // same per-instance alert hack as [pause] and leaves the same escapable
    // alert behind (PAUSE-030).
    if (pauseTimersUsesAlertHack(
        isAndroid: hostIsAndroid, isIOS: hostIsIOS, isMacOS: hostIsMacOS)) {
      _pauseHack.notePauseIssued();
    }
    return _native(_c.pauseTimers);
  }

  @override
  Future<void> resumeAllJsTimers() => _native(_c.resumeTimers);

  @override
  Future<void> stopLoading() => _native(_c.stopLoading);

  @override
  Future<void> clearCache() => _native(_c.clearCache);

  @override
  Future<Uint8List?> saveState() async => await _native(_c.saveState);

  @override
  Future<bool> restoreState(Uint8List state) async =>
      await _native(() => _c.restoreState(state)) ?? false;
}

/// Marks the [_WebViewController] of the webview under it disposed when that
/// webview leaves the tree, the frame the plugin disposes the native
/// controller. Sits directly over the `InAppWebView` and carries its key, so
/// the two elements live and die together.
class _ControllerScope extends StatefulWidget {
  const _ControllerScope({
    super.key,
    required this.onUnmount,
    required this.child,
  });

  final VoidCallback onUnmount;
  final Widget child;

  @override
  State<_ControllerScope> createState() => _ControllerScopeState();
}

class _ControllerScopeState extends State<_ControllerScope> {
  // The plugin keeps answering through the callbacks of the widget that
  // created the native view, so a later widget's callback never names it.
  late final VoidCallback _onUnmount;

  @override
  void initState() {
    super.initState();
    _onUnmount = widget.onUnmount;
  }

  @override
  void dispose() {
    _onUnmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// HTML rendered when a file-import site has no cached HTML available
/// (incognito session, post-upgrade cache wipe, …). Loaded via
/// `InAppWebViewInitialData` so chromium never tries to fetch the synthetic
/// `file:///<filename>` URL — that would surface as `ERR_INVALID_URL` /
/// `ERR_FILE_NOT_FOUND` since no real file exists on disk for the import.
String buildFileImportFallbackHtml(String initialUrl) {
  // initialUrl is `file:///filename.html` for new imports and
  // `file://filename.html` (or `file://filename.html/`) for legacy data
  // that hasn't been migrated yet. Strip the scheme + leading slashes
  // for display.
  final stripped = initialUrl.replaceFirst(RegExp(r'^file:/+'), '');
  final fileName = stripped.endsWith('/')
      ? stripped.substring(0, stripped.length - 1)
      : stripped;
  final escapedName = htmlEscape.convert(fileName);
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Imported file unavailable</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    max-width: 32em;
    margin: 3em auto;
    padding: 0 1em;
    line-height: 1.5;
  }
  h1 { font-size: 1.4em; }
  code {
    background: rgba(127,127,127,0.18);
    padding: 0.1em 0.35em;
    border-radius: 3px;
  }
  p { color: rgba(0,0,0,0.78); }
  @media (prefers-color-scheme: dark) {
    p { color: rgba(255,255,255,0.78); }
  }
</style>
</head>
<body>
<h1>Imported file unavailable</h1>
<p>The contents of <code>$escapedName</code> were imported as a local file
and aren't cached on this device any more (incognito sessions don't
persist, and the cache is cleared on app upgrade).</p>
<p>Re-import the file from the "Add new site" screen to view it again.</p>
</body>
</html>
''';
}

/// The document a file-import webview renders in place of its URL
/// (IMPORT-005, BUG-017).
///
/// The import's `file:///<name>` URL is a synthetic handle with nothing
/// behind it, so the engine must never be asked to fetch it. The controller
/// renders [html] instead when a load targets [url] (the deferred first load
/// of LEAK-003, the resume reissue of PAUSE-022) and, on WebKit, on every
/// reload: `FrameLoader::reload` re-requests the document's URL and drops the
/// bytes the page was rendered from, fails provisionally, and never reaches
/// the `onLoadStop` that ends the pull-to-refresh indicator and the loading
/// bar. Chromium keeps those bytes on the navigation entry, so its reload
/// stays native there; re-rendering would push a history entry per refresh.
class FileImportDocument {
  const FileImportDocument({required this.url, required this.html});

  /// Null unless [initialUrl] is a file import. [initialHtml] is the stored
  /// import; the "unavailable" page stands in when it is missing.
  static FileImportDocument? of({
    required String initialUrl,
    String? initialHtml,
  }) {
    if (!initialUrl.startsWith('file://')) return null;
    return FileImportDocument(
      url: initialUrl,
      html: initialHtml ?? buildFileImportFallbackHtml(initialUrl),
    );
  }

  final String url;
  final String html;

  bool isLoadOf(String target) =>
      _withoutFragment(target) == _withoutFragment(url);

  static bool rendersOnReload({required bool isAndroid}) => !isAndroid;

  static String _withoutFragment(String u) {
    final i = u.indexOf('#');
    return i < 0 ? u : u.substring(0, i);
  }
}

/// The container and proxy a WebView is built with ([WebViewFactory.storeBinding]).
///
/// [releasesContainerProxy]: the container still carries a proxy this
/// process gave it and the site no longer names one, so it has to be
/// cleared ([ProxyManager.releaseContainerProxy]) before the first load.
typedef StoreBinding = ({
  String? containerId,
  inapp.ProxySettings? proxy,
  bool proxyUnavailable,
  bool proxyConfigured,
  bool releasesContainerProxy,
});

/// Factory for creating webviews
/// A site's page loaded with no view, for one background wake (NOTIF-016).
/// Built by [WebViewFactory.openHeadlessCheck].
class HeadlessSiteCheck {
  HeadlessSiteCheck._();

  late final inapp.HeadlessInAppWebView _webview;
  inapp.InAppWebViewController? _controller;
  bool _loading = false;
  bool _gone = false;
  bool _disposed = false;

  /// Null once the page is gone: disposed, or its renderer died.
  bool? get isLoading => _gone || _disposed ? null : _loading;

  Future<String?> title() async {
    final c = _controller;
    if (c == null || _gone || _disposed) return null;
    return c.getTitle();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _webview.dispose();
  }
}

class WebViewFactory {
  /// How Android draws a webview (PAUSE-032). True, the default, is hybrid
  /// composition: the WebView sits in the Android view hierarchy and Flutter
  /// draws into image views around it, where a surface can reattach without a
  /// paint and stay blank white (BUG-001). False is texture layer hybrid
  /// composition, where the page renders into a texture Flutter composites in
  /// its own frame; it is an experimental feature (DEVTOOLS-011).
  ///
  /// Set once at startup and never after, so every webview in a process runs
  /// the same mode. The fork's `setSettings` replaces the native settings
  /// wholesale and the Dart settings class defaults this field to true, so
  /// every `InAppWebViewSettings` the app builds must carry it or a settings
  /// update flips a texture webview's native input and selection code to
  /// hybrid behaviour.
  static bool hybridComposition = true;

  /// One per process, shared by root and nested webviews: a host that answered
  /// an upgrade with a failure in one must not be probed again by the other
  /// (HTTPS-002).
  static final HttpsUpgradeEngine httpsUpgrade = HttpsUpgradeEngine();

  /// System font scale → webview text zoom percent. Tracks the OS-level
  /// "font size" accessibility setting so web content matches the size
  /// users see in their system browser.
  static int systemTextZoomPercent() {
    final scale = WidgetsBinding.instance.platformDispatcher.textScaleFactor;
    return (scale * 100).round();
  }

  /// The view's CSS-pixel width in each orientation, `(portrait,
  /// landscape)`. The page-zoom shim pins the layout viewport against
  /// these because everything reachable from the page is either spoofed
  /// (`screen.*`, by the anti-fingerprinting shim) or already moved by the
  /// zoom itself (`innerWidth`). Zero when no view is attached.
  static (double, double) _viewExtents() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView ??
        (WidgetsBinding.instance.platformDispatcher.views.isEmpty
            ? null
            : WidgetsBinding.instance.platformDispatcher.views.first);
    if (view == null || view.devicePixelRatio <= 0) return (0, 0);
    final w = view.physicalSize.width / view.devicePixelRatio;
    final h = view.physicalSize.height / view.devicePixelRatio;
    if (w <= 0 || h <= 0) return (0, 0);
    return (math.min(w, h), math.max(w, h));
  }

  /// Determine if a navigation was triggered by a user gesture.
  /// Android: uses hasGesture property.
  /// iOS/macOS: uses navigationType (LINK_ACTIVATED = user tap, FORM_SUBMITTED = user form).
  static bool _hasUserGesture(inapp.NavigationAction action) {
    if (hostIsAndroid) {
      return action.hasGesture ?? true;
    }
    if (hostIsIOS || hostIsMacOS) {
      return action.navigationType == inapp.NavigationType.LINK_ACTIVATED ||
             action.navigationType == inapp.NavigationType.FORM_SUBMITTED;
    }
    return true; // Default allow on unknown platforms
  }

  static bool _shouldBlockUrl(String url) {
    // Allow about:blank and about:srcdoc - required for Cloudflare Turnstile
    if (url.startsWith('about:') && url != 'about:blank' && url != 'about:srcdoc') return true;
    if (url.contains('/sw_iframe.html') || url.contains('/blank.html') || url.contains('/service_worker/')) return true;
    return false;
  }

  static const _captchaDomains = [
    'challenges.cloudflare.com',
    'hcaptcha.com',
  ];

  /// Domains that legitimately serve reCAPTCHA at /recaptcha/ paths.
  static const _recaptchaDomains = [
    'google.com',
    'gstatic.com',
    'recaptcha.net',
    'googleapis.com',
  ];

  static bool _matchesDomain(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  /// Whether [host] is the site at [siteUrl] or one of its subdomains, or
  /// the site is a subdomain of it.
  static bool _sameSite(String host, String? siteUrl) {
    final siteHost = siteUrl == null ? '' : (Uri.tryParse(siteUrl)?.host ?? '');
    if (siteHost.isEmpty) return false;
    return _matchesDomain(host, siteHost) || _matchesDomain(siteHost, host);
  }

  /// A captcha URL loads in place and may open the verification popup, so
  /// the Cloudflare path markers, which any origin can put in a path, count
  /// only on the site's own domain ([siteUrl]); Cloudflare serves the
  /// interstitial from the protected origin itself (CAPTCHA-010).
  @visibleForTesting
  static bool isCaptchaChallenge(String url, {String? siteUrl}) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host;
    if (host.isEmpty) return false;
    // Exact captcha domains (hcaptcha, Cloudflare challenges, which is also
    // where the Turnstile widget iframe is served from).
    if (_captchaDomains.any((d) => _matchesDomain(host, d))) return true;
    // Match the PATH only: a substring test on the whole URL let any origin
    // claim a challenge with an attacker-chosen query or fragment
    // (`https://evil.example/x?cf-turnstile`).
    if ((uri.path.contains('/cdn-cgi/challenge-platform') ||
            uri.path.contains('cf-turnstile')) &&
        _sameSite(host, siteUrl)) {
      return true;
    }
    // reCAPTCHA: /recaptcha/ path only on known Google-owned domains
    if (uri.path.contains('/recaptcha/') &&
        _recaptchaDomains.any((d) => _matchesDomain(host, d))) {
      return true;
    }
    return false;
  }

  /// The per-site store + proxy binding a WebView must carry, derived from
  /// [config]'s posture alone so a popup binds to the same container and
  /// proxy as the site that opened it.
  static StoreBinding _bindingFor(WebViewConfig config) =>
      storeBinding(config.posture);

  /// [_bindingFor] from the posture, for a caller that has to act on the
  /// binding before the WebView's config exists.
  static StoreBinding storeBinding(SitePosture posture) {
    final siteId = posture.siteId;
    // Container API binding. Stock flutter_inappwebview's `prepare()`
    // does session-bound ops (addJavascriptInterface,
    // addDocumentStartJavaScript, setAcceptThirdPartyCookies) BEFORE
    // `onWebViewCreated` fires, which locks the WebView to the default
    // store and made our earlier post-hoc-bind approach silently leak
    // across sites. The WebSpace fork's `containerId` field on
    // `InAppWebViewSettings` is read by `prepare()` /
    // `preWKWebViewConfiguration` and binds the WebView to the named
    // container before any session-bound op runs. `cachedSupported` is
    // already platform-aware (Windows / web fall through to the stub
    // which returns false); no extra Platform gate needed.
    // Archive-tier sites (ARCH-007) pass an opaque
    // [archiveContainerId] derived from `HMAC(archiveKey, "container:" +
    // siteId)`, so directory listings under the native container roots
    // expose neither the cleartext archive siteId nor a count delta
    // that correlates 1:1 with archive contents.
    // iOS/macOS/Linux ignore containerId under incognito: the fork
    // short-circuits to an ephemeral store, so binding nothing is right
    // there. Android has no ephemeral profile at all; the fork's
    // setIncognito only wipes the default jar and disables the cache, and
    // the androidx default Profile is persistent on disk. An unbound
    // incognito or archive-tier site there would share `app_webview/Default`
    // with every other such site and leave its storage behind after the
    // archive closes (ARCH-006/ARCH-007). So Android always binds a named
    // profile and relies on the existing teardown: incognito ids are deleted
    // at startup and archive container ids at close.
    final containerId = containerIdFor(
      siteId: siteId,
      archiveContainerId: posture.container.archiveContainerId,
      incognito: posture.container.incognito,
    );

    // Per-site proxy delivery, on the platforms that bind it to the
    // WebView's own network store rather than process-wide:
    //
    //   iOS 17+ / macOS 14+ — the fork's `preWKWebViewConfiguration` writes
    //     it onto `WKWebsiteDataStore.proxyConfigurations`.
    //   Linux (WPE) — the fork pins it to the container's own
    //     `WebKitNetworkSession` via
    //     `webkit_network_session_set_proxy_settings`. Proxies are per
    //     session there, so two containers hold two different proxies at
    //     once.
    //
    // A Linux site with no container has no session to pin, so it stays on
    // the process-wide override path below, as it always has.
    //
    // On Android the global `inapp.ProxyController` path runs from
    // `WebViewModel._applyProxySettings` instead, so leave `proxySettings`
    // null and avoid sending a no-op object to the native side.
    // resolveEffectiveProxy keeps these WebViews in sync with the Dart-side
    // and Android paths: per-site DEFAULT falls through to the app-global
    // outbound proxy, so a site the user hasn't customized still inherits a
    // global Tor / corporate proxy. Explicit per-site values win.
    // The named binding (PROXY-027) answers the process-level half: Apple
    // carries a proxy on the store, everything else on one process rule.
    // Linux adds a per-SITE condition on top that no process-level value
    // can express -- a container owns a `WebKitNetworkSession` and a site
    // without one has no session to pin -- so that half stays a test here.
    final bindsProxyPerSite = ProxyManager.binding == ProxyBinding.perSite ||
        (hostIsLinux && containerId != null);
    // What this site claims, resolved once: a per-site DEFAULT falls through
    // to the app-global outbound proxy, so a site the user has not customized
    // still inherits a global Tor / corporate proxy (PROXY-011).
    final claimedProxy =
        resolveEffectiveProxy(posture.container.proxy, siteId: siteId);
    final effectiveProxy = bindsProxyPerSite ? claimedProxy : null;
    // Router mode wins over the site's own rule: under it every store points
    // at the relay and the per-site choice is made there. Not gated on the
    // site having a proxy, because a store that is not pointed at the relay
    // cannot answer the PROXY-015 probe.
    //
    // Null on Apple unless a parity test opted in: the relay is Android's
    // answer to having one process-wide rule, and an Apple store binds its
    // real upstream itself. See ProxyRouterService.appleRelayEnabled.
    final relayProxy = PlatformInfo.isProxySupported
        ? routerRelayProxyFor(
            siteId: siteId, ownsContainer: containerId != null)
        : null;
    final inappProxy = relayProxy ??
        (effectiveProxy != null && PlatformInfo.isProxySupported
            ? userProxyToInappProxy(effectiveProxy)
            : null);
    // Fail closed: on iOS/macOS/Linux the per-site proxy is bound here via
    // `proxySettings`. If the site expects a non-DEFAULT proxy but the
    // address is malformed (e.g. a hand-edited backup that bypassed UI
    // validation), or the OS is below the `proxyConfigurations` floor,
    // `inappProxy` is null and the webview would otherwise load over the
    // device IP. Blank the initial load instead of leaking.
    final proxyUnavailable = effectiveProxy != null &&
        effectiveProxy.type != ProxyType.DEFAULT &&
        inappProxy == null;
    // The fork keeps a container's proxy until it is cleared by name: a
    // WebView built naming none leaves the previous one in force (PROXY-029).
    final releasesContainerProxy = ProxyManager.containerProxies.mustRelease(
      bindsProxyPerSite: bindsProxyPerSite,
      containerId: containerId,
      siteNamesProxy: effectiveProxy != null,
      boundProxy: inappProxy != null,
      proxyUnavailable: proxyUnavailable,
    );
    return (
      containerId: containerId,
      proxy: inappProxy,
      proxyUnavailable: proxyUnavailable,
      proxyConfigured: claimedProxy.type != ProxyType.DEFAULT,
      releasesContainerProxy: releasesContainerProxy,
    );
  }

  /// [WebViewConfig] of the webview that asked for a popup window, keyed by
  /// the `windowId` the host UI is handed. The host builds the popup widget
  /// from a `BuildContext` that knows nothing about the site, so the parent's
  /// posture would otherwise be lost between `onCreateWindow` and
  /// [createPopupWebView] — and a popup with no shims, no container and no
  /// proxy is a hole straight through every per-site setting.
  static final Map<int, WebViewConfig> _popupParentConfigs = {};

  /// One passkey ceremony at a time across every webview (PASSKEY-006).
  static final PasskeyCeremonyGate _passkeyGate = PasskeyCeremonyGate();

  /// Numbers each passkey request for the log, which names no origin.
  static int _passkeyRequests = 0;

  /// The prefix of every gate key this webview's ceremonies hold.
  static String _passkeyWebviewKey(inapp.InAppWebViewController controller) =>
      'wv${identityHashCode(controller)}';

  /// Create a popup webview for handling window.open() calls.
  /// Used for Cloudflare challenges and other popups that require a real window.
  ///
  /// [config] defaults to the parent webview's, recorded when the popup was
  /// requested. The popup inherits its identity (UA, shims, user scripts),
  /// its store binding and its proxy: it is the same site, in a dialog.
  static Widget createPopupWebView({
    required int windowId,
    WebViewConfig? config,
    VoidCallback? onCloseWindow,
  }) {
    final parent = config ?? _popupParentConfigs[windowId];
    if (parent == null) {
      // No parent posture to inherit means we cannot tell what the popup is
      // allowed to be. Render nothing rather than a fully-privileged webview.
      return const SizedBox.shrink();
    }
    final binding = _bindingFor(parent);
    // Same fail-closed rule as the site webview: a proxy the site expects but
    // the platform cannot honor must not become a direct connection.
    if (binding.proxyUnavailable) return const SizedBox.shrink();
    ProxyManager.noteStoreProxy(binding.containerId, binding.proxy);
    final page = _buildPageScripts(parent);
    final httpAuth = _httpAuthSessionFor(parent);
    final settings = _siteSettings(
      binding,
      parent.posture,
      textZoom: page.textZoom,
      desktopMode: page.desktopMode,
    );
    _WebViewController? view;
    final popup = inapp.InAppWebView(
      windowId: windowId,
      initialSettings: settings,
      initialUserScripts: UnmodifiableListView(page.userScripts),
      onWebViewCreated: (controller) {
        view = _WebViewController(controller,
            pauseHack: PauseTimersHackState(), settings: settings);
        _registerPageHandlers(
          controller,
          parent,
          userScriptService: page.userScriptService,
          sourceUrl: () => parent.initialUrl,
        );
      },
      // The popup exists for one challenge: its documents pass the site's
      // DNS and content-blocker checks, and its top document stays on a
      // captcha host or the site's own domain (CAPTCHA-010).
      shouldOverrideUrlLoading: (_, navigationAction) async =>
          _onSiteNavigationPolicy(parent, navigationAction,
              allowCaptcha: true),
      onCloseWindow: (controller) {
        onCloseWindow?.call();
      },
      // Honor the same trust list as the parent webview, but never
      // prompt — a popup is a child of a flow the user already
      // approved, and surfacing a second dialog inside a Cloudflare
      // verification iframe would be more confusing than the cancel
      // it falls back to.
      onReceivedServerTrustAuthRequest: (controller, challenge) =>
          _handleServerTrust(view, challenge, null),
      // A popup is the same site in a dialog, so it presents the same
      // router credential (PROXY-013) and the same saved sign-ins.
      onReceivedHttpAuthRequest: (controller, challenge) =>
          answerHttpAuthChallenge(
            routerIdentity: _routerIdentityForConfig(parent),
            session: httpAuth,
            challenge: challenge,
          ),
    );
    return _ControllerScope(
      onUnmount: () => view?._disposed = true,
      child: popup,
    );
  }

  /// The native settings that follow from the site's posture, shared by the
  /// site's webview and the popups it spawns, so a popup is held to the same
  /// identity and Tracking Protection settings as its opener.
  static inapp.InAppWebViewSettings _siteSettings(
    StoreBinding binding,
    SitePosture posture, {
    required int textZoom,
    required bool desktopMode,
  }) {
    final tp = posture.fingerprint.trackingProtection;
    return inapp.InAppWebViewSettings(
      containerId: binding.containerId,
      proxySettings: binding.proxy,
    )
      ..javaScriptEnabled = posture.page.javascript
      ..userAgent = posture.page.userAgent
      // Sec-CH-UA*/navigator.userAgentData on Android come from a separate
      // metadata object — not the UA string. Without this override the
      // wire-level UA-CH headers contradict the spoofed UA. Silently
      // ignored on iOS/macOS/Linux (no equivalent native API).
      ..userAgentMetadata = buildUserAgentMetadata(posture.page.userAgent)
      // Folded under the Tracking Protection umbrella (Android only; the
      // fork ignores both on iOS/macOS/Linux). When ETP is on: an empty
      // allow-list suppresses the `X-Requested-With: <package>` header for
      // every origin, and Attribution Reporting registration is disabled.
      // When ETP is off, leave the native defaults untouched (null). For the
      // Media Integrity API we keep it enabled-without-app-identity rather than
      // fully disabling it: that preserves legitimate anti-fraud attestation
      // while stripping the app package/signing identity that any origin
      // (including non-DRM trackers) could otherwise read.
      ..requestedWithHeaderOriginAllowList = tp ? const <String>{} : null
      ..attributionRegistrationBehavior =
          tp ? inapp.AttributionBehavior.DISABLED : null
      ..webViewMediaIntegrityApiStatus = tp
          ? inapp.WebViewMediaIntegrityApiStatus.ENABLED_WITHOUT_APP_IDENTITY
          : null
      // No-op on platforms and providers without the feature.
      ..backForwardCacheEnabled = AppPref.backForwardCacheEnabled.value
      ..thirdPartyCookiesEnabled = posture.container.thirdPartyCookies
      ..incognito = posture.container.incognito
      ..textZoom = textZoom
      ..supportZoom = true
      ..useShouldOverrideUrlLoading = true
      // Required for Cloudflare Turnstile and other challenge systems
      ..domStorageEnabled = true
      ..databaseEnabled = true
      ..javaScriptCanOpenWindowsAutomatically = true
      // Enable browser-level resource caching for offline sub-resource loading
      ..cacheEnabled = true
      // Desktop content mode mirrors the per-site UA: a desktop-shaped UA
      // turns on the plugin's `setDesktopMode(true)` path, which flips
      // useWideViewPort + loadWithOverviewMode + zoom on Android and
      // WKWebpagePreferences.preferredContentMode = .desktop on iOS.
      ..preferredContentMode = desktopMode
          ? inapp.UserPreferredContentMode.DESKTOP
          : inapp.UserPreferredContentMode.RECOMMENDED
      // Enable DevTools inspection in debug mode (chrome://inspect on Android)
      ..isInspectable = kDebugMode
      ..useHybridComposition = WebViewFactory.hybridComposition;
  }

  /// The navigation rule of a webview that is the site but not the site's
  /// own tab: a popup ([createPopupWebView]) or a background check
  /// ([openHeadlessCheck]). Every document passes the site's DNS and
  /// content-blocker checks, and the top document stays on the site's own
  /// domain, or on a captcha host when [allowCaptcha].
  static inapp.NavigationActionPolicy _onSiteNavigationPolicy(
    WebViewConfig config,
    inapp.NavigationAction navigationAction, {
    required bool allowCaptcha,
    bool refusePlainHttp = false,
  }) {
    final url = navigationAction.request.url?.toString() ?? '';
    if (_shouldBlockUrl(url)) return inapp.NavigationActionPolicy.CANCEL;
    if (url.startsWith('about:')) return inapp.NavigationActionPolicy.ALLOW;
    final verdict = _judgeAndRecord(
      config,
      UrlQuery(url, sourceUrl: config.initialUrl, requestType: 'document'),
    );
    if (verdict is! Allowed) return inapp.NavigationActionPolicy.CANCEL;
    if (navigationAction.isForMainFrame == false) {
      return inapp.NavigationActionPolicy.ALLOW;
    }
    if (refusePlainHttp && url.startsWith('http://')) {
      return inapp.NavigationActionPolicy.CANCEL;
    }
    final host = Uri.tryParse(url)?.host ?? '';
    if (url.startsWith('http') &&
        ((allowCaptcha && isCaptchaChallenge(url, siteUrl: config.initialUrl)) ||
            _sameSite(host, config.initialUrl))) {
      return inapp.NavigationActionPolicy.ALLOW;
    }
    return inapp.NavigationActionPolicy.CANCEL;
  }

  /// DNT and Sec-GPC on every navigation the app issues, and the site's
  /// language when it has one.
  static Map<String, String> _navigationHeaders(WebViewConfig config) => {
        'DNT': '1',
        'Sec-GPC': '1',
        if (config.posture.page.language case final language?)
          'Accept-Language': '$language, *;q=0.5',
      };

  /// Opens [config]'s site in a headless webview for a background wake
  /// (NOTIF-016) and starts loading [WebViewConfig.initialUrl]. Returns the
  /// check, or why there is none; a check is the caller's to dispose.
  ///
  /// It is the site in every way that reaches the network or the page:
  /// container, proxy, user agent, shims, user scripts, blockers, and the
  /// notification polyfill's handler. It has no user, so it is stricter than
  /// the site's tab: the top document stays on the site, no window opens,
  /// every permission and JS dialog is declined, downloads are dropped, an
  /// untrusted certificate is refused unless already pinned, and an HTTP
  /// auth challenge is answered only from saved sign-ins.
  static Future<(HeadlessSiteCheck?, WakeSkip?)> openHeadlessCheck(
      WebViewConfig config) async {
    final binding = _bindingFor(config);
    // SEC-009: a proxy the site expects but the platform cannot bind must
    // not become a direct connection.
    if (binding.proxyUnavailable) return (null, WakeSkip.proxyUnavailable);
    ProxyManager.noteStoreProxy(binding.containerId, binding.proxy);
    final posture = config.posture;
    BlockStatsService.instance
        .setSiteContributes(posture.siteId, posture.blocking.contributesStats);
    final page = _buildPageScripts(config);
    final httpAuth = _httpAuthSessionFor(config);
    final check = HeadlessSiteCheck._();
    final created = Completer<inapp.InAppWebViewController>();
    String? loadStartUrl;
    final headless = inapp.HeadlessInAppWebView(
      initialSettings: _siteSettings(
        binding,
        posture,
        textZoom: page.textZoom,
        desktopMode: page.desktopMode,
      )
        ..useShouldInterceptRequest = false
        ..useOnLoadResource = false
        ..supportMultipleWindows = false
        ..javaScriptCanOpenWindowsAutomatically = false
        // Nothing plays in a check: no one is there to hear it, and on iOS
        // audio would ride the background audio session (NOTIF-015).
        ..mediaPlaybackRequiresUserGesture = true,
      initialUserScripts: UnmodifiableListView(page.userScripts),
      onWebViewCreated: (controller) {
        _registerPageHandlers(
          controller,
          config,
          userScriptService: page.userScriptService,
          sourceUrl: () => loadStartUrl,
        );
        if (!created.isCompleted) created.complete(controller);
      },
      // HTTPS-001 with no fallback: a check that cannot reach the site over
      // https fails rather than going out in plaintext.
      shouldOverrideUrlLoading: (_, navigationAction) async =>
          _onSiteNavigationPolicy(config, navigationAction,
              allowCaptcha: false,
              refusePlainHttp: posture.blocking.httpsUpgrade),
      onLoadStart: (_, url) {
        loadStartUrl = url?.toString();
        check._loading = true;
      },
      onLoadStop: (_, _) => check._loading = false,
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame ?? true) check._loading = false;
      },
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => inapp.PermissionResponse(
        resources: request.resources,
        action: inapp.PermissionResponseAction.DENY,
      ),
      onGeolocationPermissionsShowPrompt: (_, origin) async =>
          inapp.GeolocationPermissionShowPromptResponse(
              origin: origin, allow: false, retain: false),
      onJsAlert: (_, _) async => inapp.JsAlertResponse(
          handledByClient: true, action: inapp.JsAlertResponseAction.CONFIRM),
      onJsConfirm: (_, _) async => inapp.JsConfirmResponse(
          handledByClient: true, action: inapp.JsConfirmResponseAction.CANCEL),
      onJsPrompt: (_, _) async => inapp.JsPromptResponse(
          handledByClient: true, action: inapp.JsPromptResponseAction.CANCEL),
      onDownloadStarting: (_, _) async => inapp.DownloadStartResponse(
          handled: true, action: inapp.DownloadStartResponseAction.CANCEL),
      // No view: an https upgrade the certificate refuses has no plaintext
      // fallback to load in a check.
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          _handleServerTrust(null, challenge, null),
      onReceivedHttpAuthRequest: (controller, challenge) =>
          answerHttpAuthChallenge(
            routerIdentity: _routerIdentityForConfig(config),
            session: httpAuth,
            challenge: challenge,
          ),
      onRenderProcessGone: (_, _) => check._gone = true,
      onWebContentProcessDidTerminate: (_) => check._gone = true,
    );
    check._webview = headless;
    final inapp.InAppWebViewController controller;
    try {
      await headless.run();
      controller = await created.future.timeout(_headlessCreateTimeout);
    } on TimeoutException {
      await check.dispose();
      return (null, WakeSkip.headlessFailed);
    } on PlatformException {
      await check.dispose();
      return (null, WakeSkip.headlessFailed);
    }
    check._controller = controller;
    // Android blocks sub-resources in a native interceptor, attached here by
    // the webview's id so it carries this site's id and level, not those of
    // whichever site next asks to attach. Without one a site that blocks
    // would load the page's trackers unfiltered, so its load never starts.
    if (hostIsAndroid) {
      final attached = await WebInterceptNative.attachToHeadless(
        headlessId: headless.id,
        siteId: posture.siteId,
        dnsLevel: config.effectiveDnsLevel,
        localCdn: posture.blocking.localCdn,
      );
      if (!attached &&
          (posture.blocking.dns ||
              posture.blocking.contentBlock ||
              posture.blocking.localCdn)) {
        await check.dispose();
        return (null, WakeSkip.blockersNotAttached);
      }
    }
    final home = Uri.tryParse(config.initialUrl);
    final url = posture.blocking.httpsUpgrade &&
            home != null &&
            home.scheme == 'http' &&
            (!home.hasPort || home.port == 80)
        ? home.replace(scheme: 'https', port: null).toString()
        : config.initialUrl;
    check._loading = true;
    try {
      await controller.loadUrl(
        urlRequest: inapp.URLRequest(
          url: inapp.WebUri(url),
          headers: _navigationHeaders(config),
        ),
      );
    } on PlatformException {
      await check.dispose();
      return (null, WakeSkip.headlessFailed);
    }
    return (check, null);
  }

  static const Duration _headlessCreateTimeout = Duration(seconds: 10);

  /// Everything the page-facing JS surface of a site needs, derived from
  /// [config] alone. Shared with [createPopupWebView] so a popup opened by a
  /// site carries the same shims as the webview that spawned it. The list is
  /// in injection order.
  static ({
    int textZoom,
    List<inapp.UserScript> userScripts,
    PageZoomPlan zoomPlan,
    bool desktopMode,
    UserScriptService userScriptService,
  }) _buildPageScripts(WebViewConfig config) {
    final posture = config.posture;
    final textZoom = systemTextZoomPercent();
    final desktopMode = isDesktopUserAgent(posture.page.userAgent);
    final zoomPlan = planPageZoom(
      zoomPercent: posture.page.zoomPercent,
      isAndroid: hostIsAndroid,
      isIOS: hostIsIOS,
      desktopMode: desktopMode,
    );
    final scoped = _scopedShims(posture);
    final userScriptService = UserScriptService(
      scripts: posture.page.userScripts,
      onConfirmScriptFetch: config.hooks.confirmScriptFetch,
      proxy: posture.container.proxy,
    );

    final userScripts = <inapp.UserScript>[
      if (scoped.webGl case final js?)
        pageShim('webgl_kill_switch', js, frames: ShimFrames.all),
      pageShim('do_not_track', buildDoNotTrackShim(), frames: ShimFrames.all),
    ];
    // Capture shims. Each asks Dart for the site's decision through its
    // kind's request handler, so the popup, the remembered choice and the
    // archive-tier override are enforced in one place. A combined audio+video
    // getUserMedia is split by the microphone shim and its video half
    // re-issued through the live entry point, so the shims compose whichever
    // order they were injected in.
    //
    // The camera and microphone reach every frame, so a QR scanner in a
    // cross-origin iframe is covered. Screen sharing does not (SHARE-005), and
    // nothing under it can back-door one: no platform this app ships offers
    // display capture to a WKWebView / Android WebView, and the Linux WPE
    // plugin denies a display-device user-media request natively before Dart
    // is consulted. Its shim re-reads `window === window.top` itself, so the
    // guard survives a platform that stops honouring the flag.
    if (config.grants != null) {
      for (final kind in CaptureKind.values) {
        userScripts.add(pageShim(
          kind.shimGroup,
          buildCaptureShim(kind),
          frames: kind.frames,
        ));
      }
    }

    userScripts.addAll([
      ..._passkeyShims(config.passkeys),
      // Cross-domain taps then reach shouldOverrideUrlLoading, which has a
      // reliable gesture, instead of onCreateWindow (issue #405).
      pageShim('target_blank_rewrite', targetBlankRewriteScript,
          frames: ShimFrames.all),
      if (scoped.antiFingerprinting case final js?)
        pageShim('anti_fingerprinting', js, frames: ShimFrames.all),
      ..._downloadShims(),
      ..._identityShims(posture, scoped, desktopMode: desktopMode),
      ..._zoomShims(posture, zoomPlan,
          textZoom: textZoom, desktopMode: desktopMode),
      pageShim(
          'notification_polyfill',
          buildNotificationPolyfillShim(
            siteId: posture.siteId,
            notificationsEnabled: posture.page.notifications,
          ),
          frames: ShimFrames.all),
      ..._mediaSessionShims(config),
      pageShim('location_spoof', scoped.location, frames: ShimFrames.all),
      ..._contentBlockerShims(config),
      if (posture.blocking.clearUrls)
        pageShim('clearurl_share', clearUrlShareScript,
            frames: ShimFrames.all),
      if (scoped.language case final js?)
        pageShim('language_override', js, frames: ShimFrames.all),
      // An iframe can create its own workers.
      if (buildWorkerShimScript(workerScopeBodies(scoped)) case final js?)
        pageShim('worker_shim', js, frames: ShimFrames.all),
      ..._blockInterceptorShims(config),
      ...userScriptService.buildInitialUserScripts(),
    ]);
    return (
      textZoom: textZoom,
      userScripts: userScripts,
      zoomPlan: zoomPlan,
      desktopMode: desktopMode,
      userScriptService: userScriptService,
    );
  }

  /// The shims whose values a worker can read too, built once for the page
  /// and its workers.
  ///
  /// Tracking Protection strips WebGL outright: the strongest answer to its
  /// fingerprint, and on Android a crash workaround, since a
  /// fingerprinter's `getContext('webgl')` walks a Chromium blocklist path
  /// that SIGTRAPs the renderer (`partition_alloc_support.cc:770`) and no
  /// setting turns WebGL off. Turning Tracking Protection off for a site
  /// brings it back for maps and 3D viewers (issue #391). The incognito
  /// fingerprint rerolls per launch (ETP-028). The location zone was resolved
  /// when the site was saved, so the polygon dataset never loads here.
  static ScopedShims _scopedShims(SitePosture p) {
    final tp = p.fingerprint.trackingProtection;
    final ua = p.page.userAgent;
    final language = p.page.language;
    final location = p.location;
    return (
      webGl: tp ? webGlKillSwitchScript : null,
      antiFingerprinting: buildAntiFingerprintingScriptSource(
        siteId: p.siteId,
        trackingProtectionEnabled: tp,
        incognito: p.container.incognito,
        launchNonce: LaunchNonce.value,
        resetNonce: p.fingerprint.resetNonce,
        letterbox: p.fingerprint.letterbox,
      ),
      identity:
          ua == null || ua.isEmpty ? null : buildUserAgentIdentityShim(ua),
      location: LocationSpoofService.buildScript(
        locationMode: location.mode,
        spoofLatitude: location.latitude,
        spoofLongitude: location.longitude,
        spoofAccuracy: location.accuracy,
        spoofTimezone: location.timezone,
        liveLocationGranularity: location.granularity,
        webRtcPolicy: location.webRtc,
      ),
      timezone: location.timezone,
      language: language == null ? null : buildLanguageShim(language),
    );
  }

  /// Passkeys through the Credential Manager bridge (PASSKEY-003), in every
  /// frame, so a cross-origin frame is refused by the handler the way
  /// Chromium refuses an undelegated one rather than by a missing API. The
  /// WebView backend needs nothing: the engine exposes WebAuthn itself.
  /// WebKit answers WebAuthn on its own with no switch to stop it, so on iOS
  /// and macOS "no passkeys" is the block shim, in every frame (PASSKEY-013).
  static List<inapp.UserScript> _passkeyShims(PasskeyAccess? passkeys) => [
        if (passkeys?.backend == PasskeyBackend.credentialManager)
          pageShim('passkey', buildPasskeyShim(), frames: ShimFrames.all),
        if (passkeys == null && PasskeyAccess.hostIsApple)
          pageShim('passkey_block', buildPasskeyBlockShim(),
              frames: ShimFrames.all),
      ];

  /// Blob downloads. The capture serves a site whose CSP `connect-src`
  /// refuses `fetch(blob:)`: [_handleBlobDownload] reads the Blob itself.
  /// Android's DownloadListener never fires for a `blob:` link, so the click
  /// is bridged too; WebKit raises onDownloadStartRequest for it natively.
  static List<inapp.UserScript> _downloadShims() => [
        pageShim('blob_url_capture', blobUrlCaptureScript,
            frames: ShimFrames.top),
        if (hostIsAndroid)
          pageShim(
              'blob_download_click_intercept', blobDownloadClickInterceptScript,
              frames: ShimFrames.top),
      ];

  /// The per-site UA's identity. A desktop UA also gets userAgentData,
  /// maxTouchPoints, matchMedia and the viewport of a desktop; any UA gets
  /// the navigator fields the host engine would otherwise fill in its own
  /// name (vendor, productSub, oscpu, buildID, platform).
  static List<inapp.UserScript> _identityShims(
    SitePosture p,
    ScopedShims scoped, {
    required bool desktopMode,
  }) =>
      [
        if (desktopMode)
          pageShim('desktop_mode_shim',
              buildDesktopModeShim(p.page.userAgent ?? ''),
              frames: ShimFrames.all),
        if (scoped.identity case final js?)
          pageShim('ua_identity_shim', js, frames: ShimFrames.all),
      ];

  /// The page's scale: WebKit's default viewport fix (desktop mode owns the
  /// viewport itself), the OS text size where there is no `textZoom`
  /// setting, and the per-site zoom on the channel [planPageZoom] picked.
  static List<inapp.UserScript> _zoomShims(
    SitePosture p,
    PageZoomPlan plan, {
    required int textZoom,
    required bool desktopMode,
  }) {
    final zoom = p.page.zoomPercent;
    final pageZoom = switch (plan.channel) {
      PageZoomChannel.none => null,
      PageZoomChannel.cssZoom => buildPageZoomCssShim(zoom),
      PageZoomChannel.viewportMeta => () {
          final (portrait, landscape) = _viewExtents();
          return buildPageZoomViewportShim(
            zoomPercent: zoom,
            pinLayoutWidth: plan.pinLayoutWidth,
            portraitWidth: portrait,
            landscapeWidth: landscape,
          );
        }(),
    };
    return [
      if ((hostIsIOS || hostIsMacOS) && !desktopMode)
        pageShim('default_viewport', defaultViewportScript,
            frames: ShimFrames.top),
      if (!hostIsAndroid)
        pageShim('system_text_zoom', buildTextZoomShim(textZoom),
            frames: ShimFrames.all),
      if (pageZoom != null)
        pageShim('page_zoom', pageZoom, frames: ShimFrames.all),
    ];
  }

  /// BGAUDIO-006, on background-audio sites only. The log line is the first
  /// link of BGAUDIO-007's chain: its absence from an App Logs export says
  /// the toggle is off, which nothing downstream can tell from a broken
  /// bridge.
  static List<inapp.UserScript> _mediaSessionShims(WebViewConfig config) {
    if (!config.backgroundAudioEnabled ||
        !MediaSessionService.instance.isSupported) {
      return const [];
    }
    LogService.instance.log('MediaSession', 'Bridge armed for this site');
    return [
      pageShim('media_session_shim', buildMediaSessionShim(),
          frames: ShimFrames.all),
    ];
  }

  /// Cosmetic filtering and `$csp=`. The early CSS hides before first paint;
  /// the generic class/id scan and the procedural actions (`:has-text()`,
  /// `:upward()`, `:remove()`) need a parsed body and the engine.
  static List<inapp.UserScript> _contentBlockerShims(WebViewConfig config) {
    if (!config.posture.blocking.contentBlock) return const [];
    final blocker = ContentBlockerService.instance;
    final url = config.initialUrl;
    final csp = blocker.cspFor(url);
    final engine = blocker.usingRustEngine;
    final procedural = engine
        ? buildProceduralCosmeticShim(blocker.proceduralActionsFor(url))
        : null;
    return [
      if (blocker.getEarlyCssScript(url) case final js?)
        pageShim('content_blocker_early_css', js, frames: ShimFrames.top),
      if (csp != null && csp.isNotEmpty)
        pageShim('content_blocker_csp', buildContentBlockerCspShim(csp),
            frames: ShimFrames.top),
      if (engine)
        pageShim('generic_cosmetic', buildGenericCosmeticScannerShim(),
            frames: ShimFrames.top, at: ShimTime.end),
      if (procedural != null)
        pageShim('procedural_cosmetic', procedural,
            frames: ShimFrames.top, at: ShimTime.end),
    ];
  }

  /// WebKit's sub-resource accounting and blocking, which Android does
  /// natively. The observer runs whether or not a list is loaded, since the
  /// per-site log reflects the visit rather than the blockers.
  static List<inapp.UserScript> _blockInterceptorShims(WebViewConfig config) {
    if (hostIsAndroid) return const [];
    final blocks = (config.effectiveDnsLevel > kDnsLevelOff &&
            DnsBlockService.instance.hasBlocklist) ||
        (config.posture.blocking.contentBlock &&
            ContentBlockerService.instance.hasRules);
    return [
      pageShim('block_resource_observer', blockResourceObserverScript,
          frames: ShimFrames.all),
      if (blocks)
        pageShim('block_js_interceptor', blockJsInterceptorScript,
            frames: ShimFrames.all),
    ];
  }

  /// The origin a camera / microphone prompt names.
  ///
  /// Never the shim's argument: the shims are injected
  /// `forMainFrameOnly: false`, so any frame can call the handler directly and
  /// would otherwise get to choose which site the dialog accuses. The top
  /// document's origin comes from the webview; a subframe's comes from the
  /// plugin's bridge preamble, which computes it behind the bridge secret and
  /// so is no more forgeable than `isMainFrame` (CAM-014 / MIC-016).
  static Future<String> _promptOrigin(
    inapp.InAppWebViewController controller,
    WebViewConfig config, {
    inapp.JavaScriptHandlerFunctionData? frame,
  }) async {
    if (frame != null && !frame.isMainFrame) return frame.origin.toString();
    return (await controller.getUrl())?.toString() ?? config.initialUrl;
  }

  /// Whether a native permission request came from the top document.
  ///
  /// The platform hands `onPermissionRequest` the requesting frame's origin
  /// but not its frame identity, so compare it with the document the webview
  /// is actually showing. Anything that does not match is a subframe and does
  /// not inherit a settled device grant (CAM-014 / MIC-016).
  static bool _sameOrigin(String a, String b) {
    final ua = Uri.tryParse(a);
    final ub = Uri.tryParse(b);
    if (ua == null || ub == null) return false;
    return ua.scheme == ub.scheme && ua.host == ub.host && ua.port == ub.port;
  }

  /// Register the Dart side of every shim [_buildPageScripts] installs.
  /// The two go together: a shim whose handler is missing leaves the
  /// promise it hands the page unresolved.
  static void _registerPageHandlers(
    inapp.InAppWebViewController controller,
    WebViewConfig config, {
    required UserScriptService userScriptService,
    required String? Function() sourceUrl,
  }) {
    // Live geolocation: forward navigator.geolocation calls from the
    // shim into the platform's native location service. Permission is
    // requested by the native plugin only when this handler is first
    // invoked — i.e. only when the page actually calls
    // getCurrentPosition / watchPosition. The handler returns a
    // serialisable map matching CurrentLocationService's JSON shape.
    if (config.posture.location.mode == LocationMode.live) {
      // GSM-granularity sites get their fixes from the platform's
      // network-positioning provider only (Android NETWORK_PROVIDER /
      // iOS kCLLocationAccuracyKilometer). The OS never escalates to
      // the fine-location permission and never powers up the GPS
      // chip. Approximate still uses the GPS provider so a fix
      // actually arrives on devices without an NLP backend — the JS
      // shim's grid-snapping is layered on top to fuzz the result
      // before the page sees it.
      final requestAccuracy =
          config.posture.location.granularity == LocationGranularity.gsm
              ? LocationAccuracy.coarse
              : LocationAccuracy.fine;
      controller.addJavaScriptHandler(
        handlerName: 'getRealLocation',
        callback: (inapp.JavaScriptHandlerFunctionData data) async {
          // The shim reaches every frame, so a cross-origin iframe can call
          // this directly and skip the engine's Permissions-Policy check.
          // Serve it what an undelegated iframe sees in a browser (LOC-011);
          // a same-origin frame keeps the default 'self' allowlist.
          if (!data.isMainFrame) {
            final top =
                (await controller.getUrl())?.toString() ?? config.initialUrl;
            if (!_sameOrigin(data.origin.toString(), top)) {
              return {'status': 'permission_denied', 'message': 'subframe'};
            }
          }
          final res = await CurrentLocationService.getCurrentLocation(
            accuracy: requestAccuracy,
          );
          if (res.status == CurrentLocationStatus.ok && res.fix != null) {
            // Apply the granularity grid-snap HERE, not only in the JS
            // shim: the shim is injected forMainFrameOnly:false, so a page
            // or cross-origin iframe can call this handler directly and
            // bypass snapFix. Snapping natively makes the per-site
            // granularity authoritative (the shim still snaps too, which
            // is now a no-op on the already-coarsened value).
            final (lat, lng, acc) = snapLiveFix(
              latitude: res.fix!.latitude,
              longitude: res.fix!.longitude,
              accuracy: res.fix!.accuracy,
              granularity: config.posture.location.granularity,
            );
            return {
              'status': 'ok',
              'latitude': lat,
              'longitude': lng,
              'accuracy': acc,
            };
          }
          return {
            'status': res.status.name,
            'message': res.message ?? 'unknown',
          };
        },
      );
    }
    // Capture bridges: a shim asks its kind's request handler for the site's
    // decision, and the store answers {mode, source?} (short-circuiting a
    // settled mode, coalescing a burst, prompting only when unresolved).
    // Frame-aware, so the origin and the frame identity reach Dart behind the
    // bridge secret, where page script can neither forge them nor call the
    // handler around them. A kind that does not reach subframes is denied one
    // HERE rather than only in its shim's realm (SHARE-005).
    final grants = config.grants;
    if (grants != null) {
      for (final kind in CaptureKind.values) {
        controller.addJavaScriptHandler(
          handlerName: kind.requestHandler,
          callback: (inapp.JavaScriptHandlerFunctionData data) async {
            if (kind.frames == ShimFrames.top && !data.isMainFrame) {
              return const {'mode': 'block'};
            }
            final grant = await grants.capture(
              kind,
              await _promptOrigin(controller, config, frame: data),
              isTopFrame: data.isMainFrame,
            );
            return grant.toBridgeJson();
          },
        );
        if (kind.publishedDevice case final device?) {
          controller.addJavaScriptHandler(
            handlerName: device.modeHandler,
            callback: (args) => grants.mode(kind).name,
          );
        }
      }
    }
    // Passkey bridge (PASSKEY-004..009). The origin Credential Manager is
    // told is the bridge's frame origin, captured by the plugin's preamble
    // before page script ran and delivered behind the bridge secret; the
    // page's arguments carry only its WebAuthn-JSON options.
    final passkeys = config.passkeys;
    if (passkeys != null &&
        passkeys.backend == PasskeyBackend.credentialManager) {
      final webviewKey = _passkeyWebviewKey(controller);
      controller.addJavaScriptHandler(
        handlerName: 'webauthnStatus',
        callback: (args) async =>
            {'available': (await PasskeyNative.status()).available},
      );
      controller.addJavaScriptHandler(
        handlerName: 'webauthnRequest',
        callback: (inapp.JavaScriptHandlerFunctionData data) async {
          final request = data.args.isNotEmpty && data.args.first is Map
              ? data.args.first as Map
              : const {};
          final label = '$webviewKey#${++_passkeyRequests}';
          final status = await PasskeyNative.status();
          if (!status.available) {
            LogService.instance.log('Passkey',
                '$label refused: Credential Manager unavailable (${status.describe})');
            return PasskeyError.unsupported.toBridgeJson();
          }
          final plan = PasskeyEngine.plan(
            op: request['op'],
            options: request['options'],
            frameOrigin: data.origin.toString(),
            isMainFrame: data.isMainFrame,
            topUrl: (await controller.getUrl())?.toString(),
            onScreen: passkeys.isOnScreen(),
          );
          final ceremony = plan.ceremony;
          if (ceremony == null) {
            LogService.instance.log(
                'Passkey', '$label refused before the provider: ${plan.error}');
            return plan.error!.toBridgeJson();
          }
          final key = '$webviewKey:${ceremony.origin}:${request['requestId']}';
          return PasskeyEngine.runCeremony(
            gate: _passkeyGate,
            key: key,
            label: label,
            ceremony: ceremony,
            send: () => PasskeyNative.run(key, ceremony),
            cancel: () => PasskeyNative.cancel(key),
            log: (message) => LogService.instance.log('Passkey', message),
          );
        },
      );
      // Keyed by the frame's origin as well as its request id, so a frame of
      // another origin in the same page cannot abort a ceremony it did not
      // start by guessing the id.
      controller.addJavaScriptHandler(
        handlerName: 'webauthnCancel',
        callback: (inapp.JavaScriptHandlerFunctionData data) {
          final origin = PasskeyEngine.serializeOrigin(data.origin.toString());
          final id = data.args.isNotEmpty ? data.args.first : '';
          final key = '$webviewKey:$origin:$id';
          if (_passkeyGate.active == key) unawaited(PasskeyNative.cancel(key));
          return null;
        },
      );
    }
    if (config.posture.blocking.clearUrls) {
      controller.addJavaScriptHandler(handlerName: 'clearUrl', callback: (args) {
        if (args.isNotEmpty && args[0] is String) {
          final original = args[0] as String;
          final cleaned = ClearUrlService.instance.cleanUrl(original);
          if (cleaned != original) {
            BlockStatsService.instance.record(
              config.posture.siteId,
              BlockCategory.trackingParam,
              label: ClearUrlService.strippedParamLabel(original, cleaned),
            );
          }
          return cleaned;
        }
        return args.isNotEmpty ? args[0] : '';
      });
    }
    // Registered whether or not a list is loaded, so allowed requests are
    // tallied too. One verdict per host the page loaded from.
    controller.addJavaScriptHandler(handlerName: 'blockResourceLoadedBatch', callback: (args) {
      if (args.isEmpty || args[0] is! List) return null;
      for (final h in args[0] as List) {
        if (h is! String || h.isEmpty) continue;
        _judgeAndRecord(config, HostQuery(h));
      }
      return null;
    });
    if (!hostIsAndroid) {
      // The WebKit interceptor's question about a Bloom hit. [sourceUrl] is
      // the hosting page, so `$domain=` rules apply.
      controller.addJavaScriptHandler(handlerName: 'blockCheck', callback: (args) {
        if (args.isEmpty || args[0] is! String) return false;
        final verdict = _judgeAndRecord(
          config,
          UrlQuery(args[0] as String,
              sourceUrl: sourceUrl() ?? '', requestType: 'other'),
        );
        return switch (verdict) {
          Allowed() => false,
          Blocked() => true,
          Redirect(:final url) => url,
        };
      });
      // One-shot merged Bloom filter delivery to JS. Bloom bits only: the
      // handler is reachable from any page, so nothing host-identifying
      // (in particular the app-wide domain-decision cache, which records
      // every host every site requests) may travel in this response.
      controller.addJavaScriptHandler(handlerName: 'getBlockBloom', callback: (args) {
        final map = Map<String, dynamic>.from(
            DnsBlockService.instance.getMergedBlockBloom().toMap());
        // Second bloom for hostless ABP network rules (path rules
        // the host bloom can't prefilter). Only when the site has
        // content blocking on — these are ABP-only.
        final cb = ContentBlockerService.instance;
        final tokenBloom =
            config.posture.blocking.contentBlock ? cb.genericNetworkTokenBloom : null;
        final fallback =
            config.posture.blocking.contentBlock && cb.hasUntokenizableNetworkRules;
        if (tokenBloom != null) {
          final tm = tokenBloom.toMap();
          map['tokenBits'] = tm['bits'];
          map['tokenBitCount'] = tm['bitCount'];
          map['tokenK'] = tm['k'];
        }
        map['genericFallback'] = fallback;
        map['hasGeneric'] = tokenBloom != null || fallback;
        return map;
      });
    }
    // The generic cosmetic scan's selectors for the page's classes and ids;
    // empty, and the shim inert, without the engine.
    controller.addJavaScriptHandler(
      handlerName: 'genericCosmeticScan',
      callback: (args) {
        if (!config.posture.blocking.contentBlock) return const <String>[];
        if (args.isEmpty || args[0] is! Map) return const <String>[];
        final payload = Map<String, dynamic>.from(args[0] as Map);
        final classes = (payload['classes'] as List? ?? const [])
            .cast<String>()
            .toSet();
        final ids = (payload['ids'] as List? ?? const [])
            .cast<String>()
            .toSet();
        final selectors =
            ContentBlockerService.instance.genericCosmeticSelectorsFor(
          pageUrl: config.initialUrl,
          classes: classes,
          ids: ids,
        );
        if (selectors.isNotEmpty) {
          final preview = selectors.take(8).join(', ');
          LogService.instance.log(
            'WebView',
            'genericCosmeticScan ${config.initialUrl}: '
                '${classes.length} class / ${ids.length} id → '
                '${selectors.length} hide(s): [$preview${selectors.length > 8 ? ", …" : ""}]',
            level: LogLevel.debug,
            sensitivity: LogSensitivity.sensitive,
          );
        }
        return selectors;
      },
    );
    // ABP rule probe diagnostics. Lets the probe page tell
    // "no cosmetic list loaded" apart from "rules present but not
    // firing", and read the engine's ABP network verdict for a
    // host directly — independent of the DNS-bloom prefilter that
    // gates the iOS sub-resource interceptor, so the probe can
    // show ABP IS deciding even when that prefilter suppresses it.
    // Registered regardless of contentBlockEnabled so it can
    // report the per-site toggle being off.
    controller.addJavaScriptHandler(
      handlerName: 'getAbpProbeStatus',
      callback: (args) async {
        final svc = ContentBlockerService.instance;
        final payload = (args.isNotEmpty && args[0] is Map)
            ? Map<String, dynamic>.from(args[0] as Map)
            : const <String, dynamic>{};
        final canaries = (payload['canaryClasses'] as List? ?? const [])
            .cast<String>()
            .toSet();
        final hosts = (payload['netHosts'] as List? ?? const [])
            .cast<String>();
        final liveUrl =
            (await controller.getUrl())?.toString() ?? config.initialUrl;
        final status =
            svc.cosmeticDiagnostics(liveUrl, canaryClasses: canaries);
        final netVerdicts = <String, bool>{
          for (final h in hosts) h: svc.isHostBlocked(h),
        };
        return {
          ...status,
          'contentBlockEnabled': config.posture.blocking.contentBlock,
          'netVerdicts': netVerdicts,
        };
      },
    );
    if (config.posture.page.notifications) {
      controller.addJavaScriptHandler(
        handlerName: 'webNotification',
        // The polyfill is in every frame. A cross-origin iframe posting
        // under the site's identity is dropped here, on the frame identity
        // the plugin supplies, not on anything the page says (NOTIF-010).
        callback: (inapp.JavaScriptHandlerFunctionData call) async {
          final args = call.args;
          if (args.isEmpty || args[0] is! Map) return null;
          if (!call.isMainFrame) {
            final top =
                (await controller.getUrl())?.toString() ?? config.initialUrl;
            if (!_sameOrigin(call.origin.toString(), top)) return null;
          }
          final data = Map<String, dynamic>.from(args[0] as Map);
          final title = data['title'] as String? ?? '';
          final body = data['body'] as String? ?? '';
          final tag = data['tag'] as String?;
          // Ignore any page-supplied siteId: a hostile script could
          // otherwise attribute a notification (and its tap-target site
          // switch) to another site the user never granted permission to.
          final siteId = config.posture.siteId;
          await NotificationService.instance.show(
            siteId: siteId,
            title: title,
            body: body,
            tag: tag,
            siteUrl: config.initialUrl,
          );
          return null;
        },
      );
    }
    if (config.backgroundAudioEnabled &&
        MediaSessionService.instance.isSupported) {
      controller.addJavaScriptHandler(
        handlerName: 'wsMediaSession',
        // Frame-aware: the shim runs in every frame of the site and they all
        // share this handler, so whether the report came from the top document
        // has to be decided here rather than taken from the page (BGAUDIO-008).
        callback: (inapp.JavaScriptHandlerFunctionData call) async {
          final args = call.args;
          if (args.isEmpty || args[0] is! Map) return null;
          final data = Map<String, dynamic>.from(args[0] as Map);
          final control = data['control'] as String?;
          if (control != null) {
            await MediaSessionService.instance.reportControlFailure(
              action: control,
              error: data['error'] as String? ?? 'unknown',
            );
            return null;
          }
          await MediaSessionService.instance.report(
            siteId: config.posture.siteId,
            frame: data['frame'] as String? ?? '',
            isMainFrame: call.isMainFrame,
            runJs: (js) => controller.evaluateJavascript(source: js),
            playing: data['playing'] as bool? ?? false,
            title: data['title'] as String? ?? '',
            artist: data['artist'] as String? ?? '',
            album: data['album'] as String? ?? '',
            artworkUrl: data['artwork'] as String? ?? '',
            proxy: config.posture.container.proxy,
          );
          return null;
        },
      );
    }
    controller.addJavaScriptHandler(
      handlerName: 'webNotificationRequestPermission',
      callback: (args) {
        final result = config.posture.page.notifications ? 'granted' : 'denied';
        LogService.instance.log('Notification', 'requestPermission handler called, returning: $result');
        return result;
      },
    );
    userScriptService.registerHandlers(controller);
    // Blob download: JS reads the blob via FileReader and hands the
    // base64 payload back through these handlers.
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobDownload',
      callback: (args) async {
        if (args.length < 4) return null;
        final filename = args[0] is String ? args[0] as String : '';
        final base64Data = args[1] is String ? args[1] as String : '';
        final mimeType = args[2] is String ? args[2] as String : '';
        final taskId = args[3] is String ? args[3] as String : '';
        if (base64Data.isEmpty) {
          if (taskId.isNotEmpty) {
            DownloadsService.instance.fail(taskId, 'empty payload');
          }
          return null;
        }
        try {
          final result = DownloadEngine.fromBase64(
            base64Data: base64Data,
            suggestedFilename: filename.isEmpty ? null : filename,
            mimeType: mimeType.isEmpty ? null : mimeType,
          );
          if (taskId.isNotEmpty) {
            DownloadsService.instance.updateProgress(taskId,
                bytesDone: result.bytes.length,
                bytesTotal: result.bytes.length);
          }
          final saved = await _saveViaPicker(result);
          if (taskId.isNotEmpty) {
            if (saved == null) {
              DownloadsService.instance.cancel(taskId);
            } else {
              DownloadsService.instance
                  .complete(taskId, savedPath: saved);
            }
          }
        } on DownloadException catch (e) {
          if (taskId.isNotEmpty) {
            DownloadsService.instance.fail(taskId, e.message);
          }
        } catch (e, stack) {
          LogService.instance.log(
            'WebView',
            'Blob download error: $e\n$stack',
            level: LogLevel.error,
            sensitivity: LogSensitivity.sensitive,
          );
          if (taskId.isNotEmpty) {
            DownloadsService.instance.fail(taskId, e.toString());
          }
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobDownloadError',
      callback: (args) {
        final msg = args.isNotEmpty ? args[0].toString() : 'unknown';
        final taskId = args.length >= 2 && args[1] is String
            ? args[1] as String
            : '';
        if (taskId.isNotEmpty) {
          DownloadsService.instance.fail(taskId, msg);
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobProgress',
      callback: (args) {
        if (args.length < 3) return null;
        final taskId = args[0] is String ? args[0] as String : '';
        final done = _asInt(args[1]);
        final total = _asInt(args[2]);
        if (taskId.isEmpty) return null;
        DownloadsService.instance.updateProgress(
          taskId,
          bytesDone: done,
          bytesTotal: total,
        );
        return null;
      },
    );
    // Android-only path: `<a download href="blob:">` clicks reach
    // Dart via the click-intercept shim, since Android's
    // DownloadListener does not fire for blob: URLs.
    // [_handleBlobDownload] is the same entry point the
    // onDownloadStartRequest path uses on iOS/macOS — keeping a
    // single funnel preserves the captured-Blob fast path and the
    // task lifecycle in DownloadsService.
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobDownloadStart',
      callback: (args) async {
        if (args.isEmpty) return null;
        final blobUrl = args[0] is String ? args[0] as String : '';
        final filename = args.length >= 2 && args[1] is String
            ? args[1] as String
            : '';
        if (blobUrl.isEmpty || !blobUrl.startsWith('blob:')) {
          return null;
        }
        await _handleBlobDownload(
          controller,
          blobUrl,
          filename.isEmpty ? null : filename,
        );
        return null;
      },
    );
  }

  static Widget createWebView({
    required WebViewConfig config,
    required Function(WebViewController) onControllerCreated,
  }) {
    // Build initial URL request headers. DNT/Sec-GPC are always-on per
    // the privacy posture of this app — every outbound nav advertises
    // the user's no-tracking preference.
    final headers = _navigationHeaders(config);

    // Declare this site's protection-report scope before any block event can
    // be recorded for it. Keyed by siteId, so a nested webview built for the
    // same site re-asserts the same answer rather than flipping it.
    BlockStatsService.instance
        .setSiteContributes(config.posture.siteId, config.posture.blocking.contributesStats);
    // Cached-HTML render: when the call site supplies
    // `config.initialHtml`, feed it to chromium via
    // `InAppWebViewInitialData(data, baseUrl: initialUrl)` for instant
    // first paint. Once the cached parse settles (`onLoadStop` for the
    // initialData), fire a one-shot `controller.reload()` to fetch the
    // live URL — which is `baseUrl`, so chromium re-loads the same
    // origin without losing the cached visual state during the
    // network round-trip.
    //
    // file:// imports are the exception — their initialUrl is a
    // synthetic `file://<filename>` handle with no fetchable form, so
    // we render the cache and never reload to live.
    //
    // The reload-to-live swap is what triggers the chromium
    // `partition_alloc_support.cc:770` dangling-raw_ptr SIGTRAP we
    // chased for many commits. That FATAL is gated by the
    // `PartitionAllocUnretainedDanglingPtr` chromium feature flag —
    // enabled on AOSP userdebug builds (where this branch was
    // originally tested), disabled in production Stable WebView.
    // Production users get the speed-up of cached first paint without
    // the dev-only crash.
    final binding = _bindingFor(config);
    final containerId = binding.containerId;
    final inappProxy = binding.proxy;
    final proxyUnavailable = binding.proxyUnavailable;
    ProxyManager.noteStoreProxy(containerId, inappProxy);
    final fileImport = FileImportDocument.of(
      initialUrl: config.initialUrl,
      initialHtml: config.initialHtml,
    );
    final isFileImport = fileImport != null;
    // When the cache is missing for a file import (incognito mode,
    // post-upgrade cache wipe, …) we feed initialData with a synthetic
    // "content unavailable" page rather than letting chromium attempt
    // to load the synthetic file:// URL — there's no actual file on
    // disk, so the load would surface as ERR_INVALID_URL or
    // ERR_FILE_NOT_FOUND in the user's face.
    // Android restore: suppress every initial-load form (URL + cached HTML)
    // so `restoreState` can apply to a pristine history. With this set, the
    // cached-HTML reload-to-live machinery below also stays off — the
    // onControllerCreated restore handler owns the first navigation instead.
    final suppressInitialLoad = config.deferInitialLoad;
    // A cached snapshot rendered against a live baseUrl fetches its
    // subresources; never do that for a site whose proxy is not bound
    // (SEC-009).
    final renderInitialData = (config.initialHtml != null || isFileImport) &&
        !suppressInitialLoad &&
        !proxyUnavailable;
    final usesCachedHtml =
        config.initialHtml != null && !suppressInitialLoad && !proxyUnavailable;
    // One-shot: when the cached HTML's first onLoadStop fires, do
    // exactly one controller.reload() to get a live page. Subsequent
    // onLoadStop events (post-reload, or for SPA navigations) leave
    // it false. Skip entirely for file:// imports and for builds
    // where we KNOW we're offline at construction (no live to fetch).
    var pendingLiveReload = usesCachedHtml && !isFileImport;

    final page = _buildPageScripts(config);
    final httpAuth = _httpAuthSessionFor(config);
    final textZoom = page.textZoom;
    final userScripts = page.userScripts;
    // Added here rather than in _buildPageScripts so a popup, which shares
    // that builder, never reports into the site's icon.
    final siteIcon = config.siteIcon;
    final iconEngine =
        siteIcon == null ? null : SiteIconEngine(siteIcon.siteUrl);
    final iconSource = pageIconSource;
    if (iconEngine != null) {
      userScripts.add(pageShim('icon_link_watcher', buildIconLinkWatcherShim(),
          frames: ShimFrames.top));
      if (iconSource == PageIconSource.webview) {
        unawaited(SiteIconNative.ensureEnabled());
      }
    }
    final siteSearch = config.siteSearch;
    if (siteSearch != null) {
      userScripts.add(pageShim(
          'search_link_watcher', buildSearchLinkWatcherShim(),
          frames: ShimFrames.top));
    }
    final iconFetcher =
        iconEngine == null || iconSource != PageIconSource.declaredLinks
            ? null
            : SiteIconFetcher(
                fetch: (url, documentUrl) => fetchPageIconBytes(
                  url,
                  documentHost: Uri.tryParse(documentUrl)?.host ?? '',
                  proxy: config.posture.container.proxy,
                  allowed: (target) =>
                      _pageIconRequestAllowed(config, target, documentUrl),
                ),
              );
    final zoomPlan = page.zoomPlan;
    final desktopMode = page.desktopMode;
    final userScriptService = page.userScriptService;

    // Track last URL that triggered onLoadStart, used to distinguish
    // SPA navigations (pushState) from real page loads in onUpdateVisitedHistory.
    String? lastLoadStartUrl;

    // Track the last URL that actually finished loading as a renderable
    // page. Updated via DownloadUrlRevertEngine.updateStable in
    // onLoadStop; consumed by the onDownloadStartRequest revert so the
    // URL bar and persisted currentUrl roll back to the referring page.
    // Initial-load fallback is handled inside the engine.
    String? lastStableUrl;

    // URL of the main-frame navigation that just failed for a network
    // reason; cleared when the next navigation starts. A failed load still
    // commits the engine's own error page and still fires `onLoadStop`, so
    // without this the HtmlCache save below serialises "connection
    // refused" over the site's last-good snapshot — which is precisely
    // what the offline path renders on the next cold start. Only the
    // ordinary-failure branch of `onReceivedError` sets it; the external
    // scheme paths there leave whatever the page managed to render intact
    // and cacheable. Compared for null rather than against `onLoadStop`'s
    // URL: platforms disagree on whether the settle reports the failing
    // URL or the error-page URL, and skipping one save costs nothing (the
    // next successful load writes the snapshot) while a missed match costs
    // the snapshot itself.
    String? failedNavUrl;

    // Monotonic counter bumped on every `shouldOverrideUrlLoading`
    // entry — i.e. every time chromium asks us about a new navigation,
    // including the synthetic invocations chromium fires for
    // server-side 3xx redirects. `onLoadStart` captures this value at
    // entry; if a later `shouldOverrideUrlLoading` bumps the counter
    // before we finish issuing IPCs against the previous frame, we bail
    // out of the remaining work. The previous frame is being torn down
    // and any further `evaluateJavascript` we post against it is bound
    // with `Unretained` lifetimes that the chromium IO thread later
    // dereferences after the frame is freed — exactly the
    // dangling-raw_ptr SIGTRAP at `partition_alloc_support.cc:770`
    // that this branch has been chasing.
    var navigationGen = 0;

    // One gate per mounted WebView, because the mounting navigation it tracks
    // is a property of the platform view and not of the site (LEAK-010).
    // Rebuilt in `onWebViewCreated` rather than only here: a remount that
    // reuses this Widget (the renderer-gone `KeyedSubtree` bump) builds a
    // fresh WKWebView, which gets a fresh mounting navigation, and a gate
    // still holding the old view's spent slot would refuse it.
    var coverageGate = ProxyCoverageGate(
      binding: ProxyManager.binding,
      proxyConfigured: binding.proxyConfigured,
      mountUrl: config.initialUrl,
    );

    // iOS Universal Link bypass state (per-WebView). Tracks URLs we
    // just cancelled-and-reissued so the second-pass shouldOverrideUrlLoading
    // call (the reissued programmatic load landing here again) doesn't
    // loop. See lib/services/ios_universal_link_bypass.dart.
    final iosUlBypass = IosUniversalLinkBypass();


    LogService.instance.log(
      'DnsBlock',
      'Creating webview: siteId=${config.posture.siteId} dnsLevel=${config.effectiveDnsLevel} hasBlocklist=${DnsBlockService.instance.hasBlocklist} isAndroid=${hostIsAndroid} url=${config.initialUrl} containerId=$containerId proxySettings=${inappProxy != null}',
      sensitivity: LogSensitivity.sensitive,
    );

    final settings = _siteSettings(
      binding,
      config.posture,
      textZoom: textZoom,
      desktopMode: desktopMode,
    )
      // Keep the Dart shouldInterceptRequest callback disabled on Android:
      // the native FastSubresourceInterceptor handles DNS blocking and
      // LocalCDN replacement for every sub-resource, whereas the Dart
      // callback only fires for main-document navigations on modern
      // Chromium WebView.
      ..useShouldInterceptRequest = false
      ..useShouldInterceptAjaxRequest = false
      ..useShouldInterceptFetchRequest = false
      ..useOnLoadResource = false
      ..supportMultipleWindows = true
      // Android: allow file and content access for Cloudflare Turnstile
      ..allowFileAccess = true
      ..allowContentAccess = true
      // When cached HTML is used, set cache-first mode from the start so
      // sub-resources (CSS/JS/images) resolve from browser cache immediately
      ..cacheMode = usesCachedHtml ? inapp.CacheMode.LOAD_CACHE_ELSE_NETWORK : null
      // iOS: play videos inline instead of auto-fullscreen
      ..allowsInlineMediaPlayback = true
      // Allow media to start without a direct tap. Android WebView defaults
      // this to true, which blocks ALL autoplay — including a getUserMedia
      // MediaStream assigned to a `<video autoplay>` (real OR the virtual
      // camera), so a QR-scan page just shows a grey frame. Every real
      // browser plays a camera stream without a gesture; match that. This is
      // Android-WebView-specific: the setting doesn't exist in the Chromium
      // that the desktop test tier drives, which is why the browser test
      // couldn't catch it.
      ..mediaPlaybackRequiresUserGesture = false
      // iOS/macOS: native Safari-style horizontal swipe for back/forward.
      // Only the root site webview opts in (see WebViewConfig.backForwardGestures).
      ..allowsBackForwardNavigationGestures = config.backForwardGestures
      // Required for onDownloadStartRequest to fire when the webview
      // navigates to a downloadable response (Content-Disposition:
      // attachment, or an unrecognized MIME type). Without this, the
      // webview silently drops the navigation and the user sees nothing.
      ..useOnDownloadStart = true;

    // Android honours the viewport meta's layout width (and thus the page
    // zoom) only when useWideViewPort is on: with it off, Chromium's
    // AdjustForAndroidWebViewQuirks clamps the layout back to device width
    // and resets the scale to 1 below 100%. The shim pairs with this by
    // spelling the width out, which keeps the same quirk's wide-viewport
    // branch (the 980px UA fallback, i.e. every site's desktop layout) out
    // of the path. loadWithOverviewMode must stay off so the WebView
    // respects our `initial-scale` rather than fitting the page to width.
    // Desktop-mode already flips these via preferredContentMode = DESKTOP.
    if (zoomPlan.needsWideViewPort) {
      settings.useWideViewPort = true;
      settings.loadWithOverviewMode = false;
    }

    // Shared between this webview's controller (which issues the pause) and
    // its `onJsAlert` (which has to recognise the pause's own alert).
    final pauseHack = PauseTimersHackState();
    final grants = config.grants;
    _WebViewController? view;

    final webViewWidget = inapp.InAppWebView(
      initialUrlRequest: (renderInitialData || suppressInitialLoad) ? null : inapp.URLRequest(
        url: inapp.WebUri(proxyUnavailable ? 'about:blank' : config.initialUrl),
        headers: proxyUnavailable || headers.isEmpty ? null : headers,
      ),
      initialData: renderInitialData ? inapp.InAppWebViewInitialData(
        data: fileImport?.html ?? config.initialHtml!,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: inapp.WebUri(config.initialUrl),
      ) : null,
      pullToRefreshController: config.pullToRefreshGate?.controller,
      initialUserScripts: UnmodifiableListView(userScripts),
      initialSettings: settings,
      // Web permission requests. Two per-site flows route through here:
      //
      // - Protected media (Android only): granting `PROTECTED_MEDIA_ID`
      //   lets the origin run EME license requests (e.g. the Spotify web
      //   player).
      // - Camera: a camera-only request (getUserMedia video, e.g. a banking
      //   site's QR scanner). In `virtual` mode the camera-stream shim
      //   intercepts getUserMedia in JS and this native request never fires,
      //   so reaching here means the shim decided `real` (or is absent) and
      //   called through to the platform. We resolve the decision and grant
      //   only for `real`, additionally ensuring the app-level CAMERA
      //   runtime permission on Android. Requests that bundle the microphone
      //   (iOS/macOS report the single resource CAMERA_AND_MICROPHONE,
      //   Android CAMERA+MICROPHONE) never reach the camera flow.
      // - Microphone: resolved the same way, and granted only for a site the
      //   user allowed that is also the one on screen. Everything else is an
      //   explicit DENY rather than the PROMPT fallback, which iOS/macOS
      //   render as WebKit's own prompt (Android/Linux would deny anyway).
      //   The combined camera+microphone resource cannot be half-granted, so
      //   it needs both decisions to be `real`; the shims normally split such
      //   a request before it reaches here.
      //
      // Screen sharing never reaches here on any platform this app ships, and
      // that is a property to preserve rather than an omission: Android
      // WebView's WebChromeClient has no display-capture resource, WKWebView
      // (iOS/macOS) routes only WKMediaCaptureType camera/microphone through
      // the plugin, and the Linux WPE plugin maps a display-device user-media
      // request to an EMPTY resource list, which it denies natively before
      // Dart is consulted. There is likewise no PermissionResourceType that
      // names a display, so nothing here could single one out even if it
      // arrived; the fallback below would deny it on Android and Linux and
      // hand it to WebKit's own prompt on iOS/macOS. If a fork bump ever adds
      // such a resource type, it must be denied explicitly right here — that
      // is what `test/screen_share_native_denial_test.dart` fails over
      // (SHARE-003).
      //
      // The fallback returns PROMPT for everything else: Android and Linux
      // WPE map any non-GRANT action to deny (their no-handler default),
      // iOS 15+/macOS 12+ show WebKit's own per-site prompt.
      onPermissionRequest: grants == null
          ? null
          : (controller, request) async {
              final wantsProtectedMedia = hostIsAndroid &&
                  request.resources.contains(
                      inapp.PermissionResourceType.PROTECTED_MEDIA_ID);
              if (wantsProtectedMedia) {
                final granted =
                    await grants.protectedContent(request.origin.toString());
                return inapp.PermissionResponse(
                  resources: [
                    inapp.PermissionResourceType.PROTECTED_MEDIA_ID
                  ],
                  action: granted
                      ? inapp.PermissionResponseAction.GRANT
                      : inapp.PermissionResponseAction.DENY,
                );
              }
              // Asked lazily: a request the app leaves to the platform needs
              // no origin.
              late final where = () async {
                final top = await _promptOrigin(controller, config);
                final from = request.origin.toString();
                final isTopFrame = _sameOrigin(top, from);
                return (origin: isTopFrame ? top : from, isTopFrame: isTopFrame);
              }();
              final cameraAndMicrophone =
                  inapp.PermissionResourceType.CAMERA_AND_MICROPHONE;
              final resources = request.resources;
              final answer = await CapturePermissionEngine.answer((
                camera: resources.contains(inapp.PermissionResourceType.CAMERA) ||
                    resources.contains(cameraAndMicrophone),
                microphone:
                    resources.contains(inapp.PermissionResourceType.MICROPHONE) ||
                        resources.contains(cameraAndMicrophone),
                other: resources.any((r) =>
                    r != inapp.PermissionResourceType.CAMERA &&
                    r != inapp.PermissionResourceType.MICROPHONE &&
                    r != cameraAndMicrophone),
              ), (
                opensDevice: (kind) async {
                  final (:origin, :isTopFrame) = await where;
                  final grant = await grants.capture(kind, origin,
                      isTopFrame: isTopFrame);
                  return opensRealDevice(grant.mode.state);
                },
                cameraPermission: CameraPermissionService.ensurePermission,
                microphonePermission:
                    MicrophonePermissionService.ensurePermission,
              ));
              return inapp.PermissionResponse(
                resources: resources,
                action: switch (answer) {
                  DeviceAnswer.grant => inapp.PermissionResponseAction.GRANT,
                  DeviceAnswer.deny => inapp.PermissionResponseAction.DENY,
                  DeviceAnswer.prompt => inapp.PermissionResponseAction.PROMPT,
                },
              );
            },
      // Android's WebChromeClient asks the app before the WebView reaches the
      // OS location service. Always deny: no mode needs this path. `off`,
      // `spoof` and a coordinate-less site are refused by the shim, and `live`
      // is served through the `getRealLocation` bridge, which applies the
      // site's granularity snapping before the fix leaves Dart. Granting here
      // would hand a live site the raw platform fix and silently bypass the
      // approximate/GSM tiers.
      //
      // The plugin already denies when this is unset, but that is its default
      // rather than our contract; wiring it makes a dependency bump unable to
      // turn pass-through back on. Android-only, ignored elsewhere.
      onGeolocationPermissionsShowPrompt: (controller, origin) async =>
          inapp.GeolocationPermissionShowPromptResponse(
            origin: origin,
            allow: false,
            retain: false,
          ),
      // A messageless alert on a webview that has been through the iOS/macOS
      // per-instance pause is that pause's own `alert()`, arriving after
      // `resumeTimers()` stopped withholding it — never something the page
      // asked for (PAUSE-030). Answer it so WebKit drops it instead of
      // presenting an empty system dialog over the app; everything else
      // returns null and keeps the plugin's default dialog.
      onJsAlert: (controller, request) async {
        if (!isEscapedPauseTimersAlert(
          pauseWasIssued: pauseHack.pauseWasIssued,
          message: request.message,
          isMainFrame: request.isMainFrame,
        )) {
          return null;
        }
        LogService.instance.log(
          'WebView',
          'Swallowed escaped pauseTimers() alert for siteId=${config.posture.siteId}',
          sensitivity: LogSensitivity.sensitive,
        );
        return inapp.JsAlertResponse(handledByClient: true);
      },
      onWebViewCreated: (controller) async {
        coverageGate = ProxyCoverageGate(
          binding: ProxyManager.binding,
          proxyConfigured: binding.proxyConfigured,
          mountUrl: config.initialUrl,
        );
        final wrappedController = view = _WebViewController(
          controller,
          pauseHack: pauseHack,
          settings: settings,
          fileImport: fileImport,
        );
        onControllerCreated(wrappedController);
        _registerPageHandlers(
          controller,
          config,
          userScriptService: userScriptService,
          sourceUrl: () => lastLoadStartUrl,
        );
        if (iconEngine != null) {
          // Frame-aware, all three: Blink and WebKit take icons from the top
          // document only, so a subframe has nothing to say about them.
          controller.addJavaScriptHandler(
            handlerName: kIconLinksChangedHandler,
            callback: (inapp.JavaScriptHandlerFunctionData call) {
              if (call.isMainFrame) iconEngine.onIconLinksChanged();
              return null;
            },
          );
          if (iconFetcher != null) {
            // Never beside onReceivedIcon: on Android the report reaches
            // Dart through a posted Java message, which onReceivedIcon can
            // overtake, so it cannot tell which document that icon came
            // from. The link report rides the same bridge, in order.
            controller.addJavaScriptHandler(
              handlerName: kIconDocumentLoadedHandler,
              callback: (inapp.JavaScriptHandlerFunctionData call) {
                if (call.isMainFrame) {
                  iconEngine
                      .onDocumentLoaded(call.requestUrl.toString())
                      .forEach(siteIcon!.onIcon);
                }
                _logSiteIcon('documentLoaded main=${call.isMainFrame} '
                    '${iconEngine.stateForLog}');
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: kIconLinksHandler,
              callback: (inapp.JavaScriptHandlerFunctionData call) {
                if (!call.isMainFrame) return null;
                final documentUrl = call.requestUrl.toString();
                final document = iconEngine.claimIconLinks(documentUrl);
                _logSiteIcon('links claim=$document ${iconEngine.stateForLog}');
                if (document == null) return null;
                final links = SiteIconLink.listFrom(
                    call.args.isEmpty ? null : call.args.first);
                final urls = siteIconCandidates(links, documentUrl);
                unawaited(iconFetcher.best(urls, documentUrl).then((icon) {
                  if (icon == null) {
                    _logSiteIcon('linked doc=$document none');
                    return;
                  }
                  final accepted = iconEngine.onLinkedIcon(document, icon.png);
                  _logSiteIcon('linked doc=$document ${icon.edge}px '
                      'taken=${accepted != null} ${iconEngine.stateForLog}');
                  if (accepted != null) siteIcon!.onIcon(accepted);
                }).catchError((Object e) {
                  LogService.instance.log('Icon', 'Page icon fetch failed: $e',
                      level: LogLevel.warning,
                      sensitivity: LogSensitivity.sensitive);
                }));
                return null;
              },
            );
          }
        }
        if (siteSearch != null) {
          // Every page of a SearXNG instance links the same description; one
          // read per webview is enough.
          final readDescriptions = <String>{};
          controller.addJavaScriptHandler(
            handlerName: kSearchLinksHandler,
            callback: (inapp.JavaScriptHandlerFunctionData call) {
              if (!call.isMainFrame || !siteSearch.enabled()) return null;
              final report = PageSearchReport.from(
                  call.args.isEmpty ? null : call.args.first);
              if (report == null) return null;
              final documentUrl = call.requestUrl.toString();
              unawaited(discoverPageSearch(
                report,
                documentUrl: documentUrl,
                siteUrl: siteSearch.siteUrl,
                fetch: (description) async {
                  if (!readDescriptions.add(description.toString())) {
                    return null;
                  }
                  return fetchPageLinkedBytes(
                    description.toString(),
                    documentHost: call.requestUrl.host,
                    proxy: config.posture.container.proxy,
                    maxBytes: kMaxOpenSearchBytes,
                    allowed: (target) => _pageIconRequestAllowed(
                        config, target, documentUrl,
                        requestType: 'other'),
                  );
                },
              ).then((found) {
                if (found != null) siteSearch.onSearch(found);
              }));
              return null;
            },
          );
        }
        // Cached-HTML → live-URL swap is wired up in onLoadStop below.
        // Don't fire loadUrl here — `onWebViewCreated` runs while chromium
        // is still parsing the initialData, and a synchronous loadUrl in
        // that window aborts the in-flight parse (load-while-loading),
        // which on Android System WebView trips a dangling-raw_ptr in the
        // renderer process at `partition_alloc_support.cc:770`.
        //
        // Container API bind happens natively inside the WebSpace fork's
        // `InAppWebView.prepare()`, driven by the `containerId` we set on
        // `InAppWebViewSettings` above. By the time `onWebViewCreated`
        // fires, the WebView is already bound to its per-site container
        // and every cookie / IDB / ServiceWorker / cache write that
        // follows is partitioned to that container.
        //
        // The WebView's own WebAuthn (PASSKEY-010), the comparison path to
        // the bridge: the engine asserts the page origin itself. Set once the
        // view is in the hierarchy, since that is where the plugin finds it.
        if (hostIsAndroid &&
            config.passkeys?.backend == PasskeyBackend.webView) {
          Future.microtask(() async {
            try {
              final kept = await PasskeyNative.setWebViewSupport('browser');
              LogService.instance.log('Passkey', 'WebView support: $kept');
            } catch (e) {
              LogService.instance.log('Passkey', 'WebView support failed: $e',
                  level: LogLevel.warning);
            }
          });
        }
        // Attach native interceptor (DNS blocking + LocalCDN serving) once
        // the view is in the hierarchy. Always attach on Android — the
        // handler no-ops cheaply when neither blocklist nor CDN cache are
        // populated, and the references are shared with the plugin so
        // subsequent updates are picked up without re-attaching.
        if (hostIsAndroid) {
          // Track attach attempts so we can correlate with the
          // native-side "attachToAllWebViews" log. Phase 14: helps
          // debug the case where Android sub-resources aren't blocked
          // — first thing to check is whether attach is even running.
          LogService.instance.log(
            'WebView',
            'requesting native interceptor attach: siteId=${config.posture.siteId} '
                'initialUrl=${config.initialUrl}',
            level: LogLevel.debug,
            sensitivity: LogSensitivity.sensitive,
          );
          Future.microtask(() => WebInterceptNative.attachToWebViews(
              siteId: config.posture.siteId,
              dnsLevel: config.effectiveDnsLevel,
              localCdn: config.posture.blocking.localCdn));
        }
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        // Bump the navigation generation FIRST. Any in-flight `onLoadStart`
        // handler from the previous navigation that's about to fire an
        // `evaluateJavascript` IPC will see the advance and skip the call,
        // so the IPC isn't bound to a frame chromium is in the middle of
        // tearing down.
        navigationGen++;
        final url = navigationAction.request.url.toString();
        if (_shouldBlockUrl(url)) return inapp.NavigationActionPolicy.CANCEL;
        // External app schemes (intent://, tel:, mailto:, market:, custom
        // app schemes) can't be rendered in a webview — flutter_inappwebview
        // returns ERR_UNKNOWN_URL_SCHEME. Cancel and hand the URL to the
        // host UI, which confirms with the user before calling url_launcher.
        // Don't call controller.stopLoading() here — chromium has crashed
        // with a dangling raw_ptr when stopLoading runs concurrently with
        // a synchronous CANCEL path. The CANCEL alone aborts the
        // navigation; if Android still paints ERR_UNKNOWN_URL_SCHEME,
        // onReceivedError handles recovery.
        final externalInfo = ExternalUrlParser.parse(url);
        if (externalInfo != null) {
          LogService.instance.log(
            'WebView',
            'External scheme intercepted: scheme=${externalInfo.scheme} '
                'package=${externalInfo.package} fallback=${externalInfo.fallbackUrl} url=$url',
            sensitivity: LogSensitivity.sensitive,
          );
          // External scheme with a resolvable web URL (intent:// fallback,
          // x-safari-http(s) force-open): route it through the standard
          // same-domain / cross-domain path, no confirmation prompt. We
          // are the browser; handing the user off to a different app for
          // a URL they clicked inside us is hostile behavior (Google Maps
          // fires intents constantly, x.com bounces every in-app-browser
          // visit to Safari). Same base domain → load in this webview;
          // cross-domain → nested via shouldOverrideUrlLoading. Schemes
          // *without* a web equivalent (zxing scanner, custom-app deep
          // links, tel:) still hit the confirmation dialog.
          final resolved = ExternalUrlParser.toWebUrl(externalInfo);
          if (resolved != null) {
            // The reissued load below lands on the top-frame controller, so
            // a subframe must not reach it (NESTED-013): an ad iframe would
            // otherwise steer the top document with the session attached.
            if (navigationAction.isForMainFrame == false) {
              return inapp.NavigationActionPolicy.CANCEL;
            }
            final hasGesture = _hasUserGesture(navigationAction);
            // Loop guard (EXT-007): x.com re-fires its Safari bounce on
            // every page render — resolving it again would reload the
            // fallback forever. A script-driven re-fire inside the
            // suppression window is dropped; a user-gesture nav is the
            // user deliberately clicking, so it always routes.
            if (!hasGesture &&
                ExternalUrlSuppressor.isSuppressedInfo(externalInfo)) {
              LogService.instance.log(
                'WebView',
                'silent route suppressed (recently routed): $url',
                sensitivity: LogSensitivity.sensitive,
              );
              return inapp.NavigationActionPolicy.CANCEL;
            }
            ExternalUrlSuppressor.mark(externalInfo);
            LogService.instance.log(
              'WebView',
              'external scheme resolved → $resolved (from $url)',
              sensitivity: LogSensitivity.sensitive,
            );
            bool allow = true;
            if (config.shouldOverrideUrlLoading != null) {
              allow = config.shouldOverrideUrlLoading!(resolved, hasGesture);
            }
            if (allow) {
              controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(resolved)));
            }
            return inapp.NavigationActionPolicy.CANCEL;
          }
          config.hooks.externalScheme(externalInfo, view);
          return inapp.NavigationActionPolicy.CANCEL;
        }
        // Counted even with no list loaded, so the per-site log reflects
        // the visit. The source is the page that started the navigation.
        final verdict = _judgeAndRecord(
          config,
          UrlQuery(url,
              sourceUrl: lastLoadStartUrl ?? '', requestType: 'document'),
        );
        if (verdict is! Allowed) return inapp.NavigationActionPolicy.CANCEL;
        // Cross-domain → nested-webview routing applies to MAIN-FRAME
        // navigations only. On Android API 24+ chromium fires
        // shouldOverrideUrlLoading for child-frame (iframe) navigations
        // as well, with `isForMainFrame == false` distinguishing them.
        // If we forwarded those into the engine we'd open every
        // embedded iframe (Google One Tap GSI, Cloudflare challenge
        // iframe, third-party SSO popups) as a separate top-level
        // webview — wrong, intrusive, and on Android can race the
        // chromium frame-lifecycle code path that the
        // `partition_alloc_support.cc:770` dangle ride sits on top
        // of. Allow iframe navigations to load in-place; the engine
        // sees only main-frame navigations.
        final isMainFrame = navigationAction.isForMainFrame ?? true;
        // Diagnostic: log the raw isForMainFrame so we can tell
        // when a platform reports null vs. true vs. false. WebKit2GTK
        // on Linux has been observed to return true for navigations
        // that originate from inside an iframe; Android API 24+
        // returns false for child-frame navigations consistently.
        LogService.instance.log('WebView',
            'shouldOverrideUrlLoading: isForMainFrame=${navigationAction.isForMainFrame}');
        if (!isMainFrame) {
          return inapp.NavigationActionPolicy.ALLOW;
        }
        // URL rewrites (ClearURLs, $removeparam) drive a load on the TOP
        // frame, so they live below the main-frame gate: a cross-origin
        // subframe navigation must never be able to steer the top document.
        // The rewrite target is likewise re-checked before it is loaded — a
        // ClearURLs redirection rule yields whatever the matched URL carried
        // in its capture group, and `loadUrl` on Android takes any scheme.
        //
        // ClearURLs: strip tracking parameters from URLs
        if (config.posture.blocking.clearUrls && ClearUrlService.instance.hasRules) {
          final cleanedUrl = ClearUrlService.instance.cleanUrl(url);
          if (cleanedUrl.isEmpty) return inapp.NavigationActionPolicy.CANCEL;
          if (cleanedUrl != url &&
              ExternalUrlParser.isLoadableWebUrl(cleanedUrl)) {
            BlockStatsService.instance.record(
              config.posture.siteId,
              BlockCategory.trackingParam,
              label: ClearUrlService.strippedParamLabel(url, cleanedUrl),
            );
            controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(cleanedUrl)));
            return inapp.NavigationActionPolicy.CANCEL;
          }
        }
        // ABP $removeparam=: a rule-driven sibling of ClearURLs. EasyList
        // & co. ship $removeparam=utm_source (etc.); the Rust engine
        // strips matching keys. Runs AFTER ClearURLs so the static
        // rules go first and the filter list catches what they miss.
        // No-op when the engine is off or the URL has no query.
        if (config.posture.blocking.contentBlock &&
            ContentBlockerService.instance.usingRustEngine &&
            url.contains('?')) {
          // requestType: 'document' — adblock-rust restricts
          // \$removeparam= to document/subdocument/xhr by default,
          // and a main-frame nav IS a document fetch. Without this
          // the engine returns no rewrite even when a matching
          // filter is loaded.
          final rewritten = ContentBlockerService.instance
              .rewrittenUrl(url, requestType: 'document');
          if (rewritten != null &&
              rewritten != url &&
              ExternalUrlParser.isLoadableWebUrl(rewritten)) {
            LogService.instance.log(
              'ContentBlocker',
              '\$removeparam= rewrote $url → $rewritten',
              level: LogLevel.debug,
              sensitivity: LogSensitivity.sensitive,
            );
            controller.loadUrl(
                urlRequest: inapp.URLRequest(url: inapp.WebUri(rewritten)));
            return inapp.NavigationActionPolicy.CANCEL;
          }
        }
        if (config.shouldOverrideUrlLoading != null) {
          final hasGesture = _hasUserGesture(navigationAction);
          final allow = config.shouldOverrideUrlLoading!(url, hasGesture);
          if (!allow) return inapp.NavigationActionPolicy.CANCEL;
        }
        // Fail closed where the platform cannot be shown to put this request
        // through the site's proxy (LEAK-010). Below the routing decision
        // above, because a navigation that decision hands to a nested webview
        // or the system browser is not a request this webview makes: the
        // nested one mounts on it, and a mounting navigation is the one the
        // store's proxy does cover. The rewrites above reach here on their
        // reissued pass, so a cleaned URL is judged on its own merits rather
        // than riding the original's decision.
        if (url.startsWith('http') &&
            coverageGate.evaluate(url) == ProxyCoverage.unprovable) {
          LogService.instance.log(
            'Proxy',
            'Navigation blocked: proxy coverage not established for $url '
                '(siteId=${config.posture.siteId})',
            level: LogLevel.warning,
            sensitivity: LogSensitivity.sensitive,
          );
          config.onUnproxiedNavigationBlocked?.call(url);
          return inapp.NavigationActionPolicy.CANCEL;
        }
        // HTTPS upgrade, decided AFTER the routing decision above for the same
        // reason the captcha allow is (HTTPS-004): taken first, a scheme
        // rewrite re-enters the pipeline with the gesture requirement and the
        // cross-domain nested route already behind it.
        final upgrade = WebViewFactory.httpsUpgrade
            .onNavigation(url, enabled: config.posture.blocking.httpsUpgrade);
        if (upgrade.armDeadlineFor != null) {
          final armed = upgrade.armDeadlineFor!;
          final genAtUpgrade = navigationGen;
          Timer(WebViewFactory.httpsUpgrade.deadline, () {
            final out = WebViewFactory.httpsUpgrade.onDeadline(
              armed,
              generationAtArm: genAtUpgrade,
              currentGeneration: () => navigationGen,
            );
            if (out.load != null) {
              LogService.instance.log(
                'WebView',
                'https upgrade timed out, falling back to ${out.load}',
                sensitivity: LogSensitivity.sensitive,
              );
              controller.loadUrl(
                  urlRequest: inapp.URLRequest(url: inapp.WebUri(out.load!)));
            }
          });
        }
        if (upgrade.load != null) {
          LogService.instance.log(
            'WebView',
            '  -> CANCEL (https upgrade) $url',
            sensitivity: LogSensitivity.sensitive,
          );
          controller.loadUrl(
              urlRequest: inapp.URLRequest(url: inapp.WebUri(upgrade.load!)));
        }
        if (upgrade.cancel) return inapp.NavigationActionPolicy.CANCEL;
                // A captcha challenge loads in place. Decided AFTER the routing
        // decision above, never before it: taken first, "is this a captcha
        // URL?" becomes a way to navigate the parent webview to any origin
        // with the gesture requirement and the cross-domain nested route
        // skipped.
        if (isCaptchaChallenge(url, siteUrl: config.initialUrl)) {
          return inapp.NavigationActionPolicy.ALLOW;
        }
        // iOS Universal Link bypass. WKWebView auto-routes user-tap
        // navigations (and redirect chains rooted in a tap) to the
        // native app for URLs whose host matches an installed app's
        // AASA — even when the user explicitly added the site to
        // WebSpace. iOS exposes no public API to detect AASA matches,
        // so the bypass treats every tap-rooted main-frame http(s)
        // navigation as at-risk: cancel + reissue via `loadUrl`.
        // WebKit treats programmatic loads as navigation type
        // `.other` and skips AASA matching, keeping the page inside
        // the webview regardless of which apps are installed. The
        // reissued nav fires `shouldOverrideUrlLoading` again; the
        // per-URL memo passes that second pass through.
        //
        // Scoped to LINK_ACTIVATED plus bodyless (GET/HEAD)
        // FORM_SUBMITTED. A body-carrying form POST is passed through:
        // reissuing it via `loadUrl` (a GET) would drop the POST body
        // and break every credentialed form on the web (logins, search,
        // payments) — LinkedIn's `/checkpoint/lg/login-submit` was the
        // canonical 404 case. But WKWebView also tags the server
        // redirect that *follows* a form POST as FORM_SUBMITTED, and
        // that hop is re-fetched as a GET (302/303 → GET). That hop is
        // exactly the one that lets Google Maps'
        // `consent.google.com/save → maps.google.com` redirect escape
        // into the native app, so a GET/HEAD FORM_SUBMITTED is eligible.
        //
        // Pure programmatic navigations (initial nav, server
        // redirects without a tap origin, pushState) carry no user
        // gesture — they don't activate AASA in the first place and
        // are passed through here without interception.
        if (hostIsIOS &&
            IosUniversalLinkBypass.isEligibleNavigation(
              isMainFrame: isMainFrame,
              url: url,
              isLinkActivated: navigationAction.navigationType ==
                  inapp.NavigationType.LINK_ACTIVATED,
              isFormSubmitted: navigationAction.navigationType ==
                  inapp.NavigationType.FORM_SUBMITTED,
              httpMethod: navigationAction.request.method,
            )) {
          if (iosUlBypass.shouldCancelAndReissue(url)) {
            LogService.instance.log(
              'WebView',
              '  -> CANCEL (iOS UL bypass: reissuing programmatically) $url',
              sensitivity: LogSensitivity.sensitive,
            );
            final originalUrl = navigationAction.request.url;
            final originalHeaders = navigationAction.request.headers;
            controller.loadUrl(urlRequest: inapp.URLRequest(
              url: originalUrl,
              headers: originalHeaders,
            ));
            return inapp.NavigationActionPolicy.CANCEL;
          }
          LogService.instance.log(
            'WebView',
            '  -> ALLOW (iOS UL bypass: reissued nav passing through)',
            sensitivity: LogSensitivity.sensitive,
          );
        }
        return inapp.NavigationActionPolicy.ALLOW;
      },
      onLongPressHitTestResult: (controller, hitTestResult) {
        if (config.onLinkLongPress == null) return;
        // Only a link. An image or a phone number long-press has nothing to
        // open in a tab, and `extra` for those is not a URL.
        if (hitTestResult.type != inapp.InAppWebViewHitTestResultType.SRC_ANCHOR_TYPE &&
            hitTestResult.type !=
                inapp.InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE) {
          return;
        }
        final extra = hitTestResult.extra;
        if (extra == null || extra.isEmpty) return;
        final uri = Uri.tryParse(extra);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return;
        }
        config.onLinkLongPress!(extra);
      },
      onCreateWindow: (controller, createWindowAction) async {
        final url = createWindowAction.request.url?.toString() ?? '';
        final windowId = createWindowAction.windowId;
        LogService.instance.log(
          'WebView',
          'onCreateWindow: url=$url windowId=$windowId',
          sensitivity: LogSensitivity.sensitive,
        );

        // Show popup dialog for Cloudflare challenges (captcha verification).
        if (isCaptchaChallenge(url, siteUrl: config.initialUrl)) {
          // The host builds the popup widget out of a BuildContext that has
          // no site attached; hand it this webview's posture by windowId so
          // createPopupWebView can inherit it. showPopup resolves when the
          // popup dialog closes, so the entry is short-lived.
          _popupParentConfigs[windowId] = config;
          try {
            await config.hooks.showPopup(windowId, url);
          } finally {
            _popupParentConfigs.remove(windowId);
          }
          return true;
        }

        // target="_blank" links can carry external app schemes too (e.g.
        // a `<a target="_blank" href="intent://...">`). Route them through
        // the same confirmation path as direct navigations.
        final externalInfo = ExternalUrlParser.parse(url);
        if (externalInfo != null) {
          LogService.instance.log(
            'WebView',
            'External scheme intercepted (onCreateWindow): '
                'scheme=${externalInfo.scheme} package=${externalInfo.package} url=$url',
            sensitivity: LogSensitivity.sensitive,
          );
          final resolved = ExternalUrlParser.toWebUrl(externalInfo);
          if (resolved != null) {
            final hasGesture = _hasUserGesture(createWindowAction);
            // Same loop guard as shouldOverrideUrlLoading (EXT-007).
            if (!hasGesture &&
                ExternalUrlSuppressor.isSuppressedInfo(externalInfo)) {
              LogService.instance.log(
                'WebView',
                'silent route suppressed (onCreateWindow, recently routed): $url',
                sensitivity: LogSensitivity.sensitive,
              );
              return false;
            }
            ExternalUrlSuppressor.mark(externalInfo);
            LogService.instance.log(
              'WebView',
              'external scheme resolved (onCreateWindow) → $resolved (from $url)',
              sensitivity: LogSensitivity.sensitive,
            );
            bool allow = true;
            if (config.shouldOverrideUrlLoading != null) {
              allow = config.shouldOverrideUrlLoading!(resolved, hasGesture);
            }
            // A window this webview did not ask for by gesture never loads
            // into it (NESTED-013); a real target="_blank" tap is rewritten
            // before it gets here (NESTED-008).
            if (allow && hasGesture) {
              controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(resolved)));
            }
            return false;
          }
          config.hooks.externalScheme(externalInfo, view);
          return false;
        }

        // For target="_blank" links (e.g., badge clicks on GitHub), delegate
        // to shouldOverrideUrlLoading which handles cross-domain navigation
        // by opening a nested webview. On iOS, target="_blank" links may
        // only trigger onCreateWindow without shouldOverrideUrlLoading.
        // Script-initiated window.open() (analytics, Stripe) have no user
        // gesture and are silently blocked by the auto-redirect check.
        if (url.startsWith('http') && config.shouldOverrideUrlLoading != null) {
          final hasGesture = _hasUserGesture(createWindowAction);
          final allow = config.shouldOverrideUrlLoading!(url, hasGesture);
          if (allow && hasGesture) {
            // Same-domain target="_blank": load in current webview
            controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(url)));
          }
        }

        return false;
      },
      // Dart shouldInterceptRequest is intentionally unset — see the
      // useShouldInterceptRequest comment above. Sub-resource DNS blocking
      // and LocalCDN replacement are both handled by the native
      // FastSubresourceInterceptor attached via WebInterceptNative.
      onProgressChanged: config.onProgressChanged == null
          ? null
          : (controller, progress) {
              config.onProgressChanged!(progress);
            },
      onLoadStart: (controller, url) async {
        LogService.instance.log(
          'WebViewLifecycle',
          'onLoadStart siteId=${config.posture.siteId} url=$url',
          sensitivity: LogSensitivity.sensitive,
        );
        // A passkey ceremony belongs to the document that started it, and a
        // main-frame load replaces that document (PASSKEY-015).
        final pendingPasskey = _passkeyGate.active;
        if (pendingPasskey != null &&
            pendingPasskey.startsWith('${_passkeyWebviewKey(controller)}:')) {
          LogService.instance.log('Passkey', 'page left, request cancelled');
          unawaited(PasskeyNative.cancel(pendingPasskey));
        }
        if (iconEngine != null) {
          iconEngine.onLoadStarted(url?.toString()).forEach(siteIcon!.onIcon);
          _logSiteIcon('loadStart ${iconEngine.stateForLog}');
        }
        // Taken before any await: see `navigationGen`.
        final myGen = navigationGen;
        bool stillCurrent() => navigationGen == myGen;

        // The server answered for an upgrade of ours, so the deadline stops
        // applying to it: a page that is slow to finish is not a connection
        // that never got going, and treating the two alike downgrades a
        // working https host on a bad link and records it http-only for the
        // rest of the session (HTTPS-002).
        if (url != null) {
          WebViewFactory.httpsUpgrade.onLoadStarted(url.toString());
        }
        config.onLoadingChanged?.call(true);
        if (url != null) {
          config.onMainFrameLoad
              ?.call(MainFrameLoadSignal.started(url.toString()));
        }

        lastLoadStartUrl = url?.toString();
        failedNavUrl = null;
        // Counted here too, so the stats banner shows a cached-HTML load
        // that never reached shouldOverrideUrlLoading.
        if (url != null && url.toString().startsWith('http')) {
          final page = url.toString();
          _judgeAndRecord(config,
              UrlQuery(page, sourceUrl: page, requestType: 'document'));
        }
        // One evaluateJavascript, not one per script: each IPC is a race
        // window against Chromium's frame teardown.
        final earlyScripts = <String>[];
        if (config.posture.blocking.contentBlock && url != null) {
          final cssScript =
              ContentBlockerService.instance.getEarlyCssScript(url.toString());
          if (cssScript != null) earlyScripts.add(cssScript);
        }
        if (config.posture.blocking.clearUrls) {
          earlyScripts.add(clearUrlShareScript);
        }
        if (earlyScripts.isNotEmpty && stillCurrent()) {
          await view?.evaluateJavascript(earlyScripts.join('\n'));
        }
        if (stillCurrent()) {
          await userScriptService.reinjectOnLoadStart(controller);
        }
      },
      // The Android plugin dispatches only this callback; onFaviconChanged,
      // its replacement, is wired for Windows alone in the pinned fork.
      // ignore: deprecated_member_use
      onReceivedIcon: iconEngine == null || iconSource != PageIconSource.webview
          ? null
          : (controller, icon) {
              final accepted = iconEngine.onIcon(icon);
              _logSiteIcon('webview ${pngDimensions(icon)?.width}px '
                  'taken=${accepted != null} ${iconEngine.stateForLog}');
              if (accepted != null) siteIcon!.onIcon(accepted);
            },
      onPageCommitVisible: (controller, url) {
        LogService.instance.log(
          'WebViewLifecycle',
          'onPageCommitVisible siteId=${config.posture.siteId} url=$url',
          sensitivity: LogSensitivity.sensitive,
        );
        config.onPageCommitVisible?.call();
      },
      onLoadStop: (controller, url) async {
        LogService.instance.log(
          'WebViewLifecycle',
          'onLoadStop siteId=${config.posture.siteId} url=$url',
          sensitivity: LogSensitivity.sensitive,
        );
        if (iconEngine != null) {
          iconEngine.onLoadFinished(url?.toString()).forEach(siteIcon!.onIcon);
          _logSiteIcon('loadStop ${iconEngine.stateForLog}');
        }
        // An upgrade that loaded is no longer in flight. Without this the
        // engine's map grows by one per upgraded navigation, and a later
        // unrelated failure on the same URL string reads as a fallback to an
        // http load that finished long ago (HTTPS-002).
        if (url != null) {
          WebViewFactory.httpsUpgrade.onLoadFinished(url.toString());
        }
        config.pullToRefreshGate?.controller?.endRefreshing();
        // Whether or not `url` is renderable: the loading UI does not
        // depend on the snapshot logic below.
        config.onLoadingChanged?.call(false);
        config.onMainFrameLoad?.call(const MainFrameLoadSignal.settled());
        if (url == null) return;
        final urlStr = url.toString();

        // Downloads, javascript: bookmarklets, and other non-renderable
        // schemes can reach here when controller.stopLoading() interrupts
        // an in-flight navigation (the download path does this to keep
        // the webview from rendering the attachment as a page). There's
        // no real page to snapshot — onHtmlLoaded would end up writing
        // either the previous page's HTML keyed under the download URL,
        // or empty content, clobbering a legitimate offline cache entry.
        // Skip all post-load work in that case; onDownloadStartRequest's
        // revert handles URL bar restoration.
        if (!DownloadUrlRevertEngine.isRenderable(urlStr)) return;

        // Cached-HTML one-shot live refresh. After the cached HTML
        // parse settles, fire a single `controller.reload()` to fetch
        // a fresh copy of the page over the network. The
        // `pendingLiveReload` flag is consumed on first use so the
        // subsequent (post-reload) onLoadStop doesn't recurse.
        //
        // Gated on `navigationGen == 0` — i.e. no shouldOverrideUrlLoading
        // has fired yet. If the user clicked anything during the cached
        // parse, gen > 0 and we skip the reload; their navigation is the
        // current intent. (`reload()` itself does not bump
        // navigationGen on Android WebView.)
        //
        // Offline, the cached page is the answer until the network comes
        // back: `awaitOnlineForLiveSwap` re-probes for a bounded window,
        // because a snapshot rendered on return from the background settles
        // before a per-app firewall lets the app back out, and a single
        // probe there stranded the snapshot for good.
        //
        // Each probe is a DNS lookup with up to a 3s timeout — long enough
        // for the user to tap a link or trigger a back/forward gesture.
        // `navigationGen` is re-checked after every probe so the
        // live-reload doesn't clobber a navigation that started meanwhile.
        final firedLiveReload = pendingLiveReload && navigationGen == 0;
        if (firedLiveReload) {
          pendingLiveReload = false;
          final genAtSchedule = navigationGen;
          awaitOnlineForLiveSwap(
            isOnline: ConnectivityService.instance.isOnline,
            stillWanted: () => navigationGen == genAtSchedule,
          ).then((online) async {
            if (!online) {
              LogService.instance.log('WebView',
                  'Cached snapshot kept: offline or navigated away');
              return;
            }
            config.onReloadIssued?.call();
            await view?.reload();
          });
        }

        lastStableUrl =
            DownloadUrlRevertEngine.updateStable(lastStableUrl, urlStr);
        config.onUrlChanged?.call(urlStr);
        final onCookiesChanged = config.onCookiesChanged;
        if (onCookiesChanged != null) {
          // The container engine reads the bound container's jar through
          // the fork's `webViewController:`; the legacy one, the shared jar.
          final container = config.hooks.containerCookieManager;
          final pageUrl = Uri.parse(urlStr);
          onCookiesChanged(container != null
              ? await container.getCookies(
                  controller: _WebViewController(controller,
                      pauseHack: pauseHack, settings: settings),
                  siteId: config.posture.siteId,
                  url: pageUrl,
                )
              : await config.hooks.cookieManager.getCookies(url: pageUrl));
        }
        // Inject full cosmetic script: MutationObserver + text-based hiding
        if (config.posture.blocking.contentBlock) {
          final script = ContentBlockerService.instance.getCosmeticScript(urlStr);
          if (script != null) await view?.evaluateJavascript(script);
        }
        await userScriptService.reinjectOnLoadStop(controller);
        // Cache HTML for offline viewing. Pre-gate the renderer IPC
        // via shouldFetchHtml so the per-onLoadStop storm is collapsed
        // before we ask chromium to serialize the DOM — the IPC, not
        // the encrypt+write afterward, is the lifecycle-racing piece.
        //
        // Skip when we just fired the cached-then-live reload above:
        // the reload IPC reaches the renderer before our snapshot
        // does, so the serialized DOM here is the partial mid-reload
        // markup (often a few-KB SPA shell) — and saving that clobbers
        // the previously-cached fully-rendered snapshot. On next launch
        // the corrupt shell loads as initialData and the SPA's hydration
        // throws (`Cannot read properties of null`) leaving a blank
        // page. The post-reload `onLoadStop` saves the live HTML
        // instead; `_lastSaveAt` isn't bumped here, so its debounce
        // stays open.
        if (config.onHtmlLoaded != null
            && !firedLiveReload
            && failedNavUrl == null
            && (config.shouldFetchHtml?.call() ?? true)) {
          final snapshot =
              await view?.evaluateJavascriptReturning(htmlSnapshotScript);
          if (snapshot is String && snapshot.isNotEmpty) {
            // `urlStr` was captured at onLoadStop entry. The snapshot is
            // an async IPC into the renderer; if the user kicked off a
            // back/forward gesture or a link tap during that round trip,
            // the markup we got back belongs to the *new* page, not
            // `urlStr`. Saving (urlStr, html-of-new-page) under `siteId`
            // poisons the cache: next webview construction renders that
            // mismatched HTML at `baseUrl=currentUrl`, so the user sees
            // the wrong page when they swipe back into the cached entry.
            // Re-read the URL post-snapshot and skip the save on
            // mismatch — the next stable onLoadStop will write the
            // right pair.
            final liveUrl = (await view?.getUrl())?.toString();
            if (liveUrl == urlStr) {
              config.onHtmlLoaded!(urlStr, snapshot);
            } else {
              LogService.instance.log(
                'WebView',
                'Skipping cache save: URL changed during snapshot '
                    '($urlStr -> $liveUrl)',
                sensitivity: LogSensitivity.sensitive,
              );
            }
          }
        }
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) {
        // Fires on every history change including back/forward gestures.
        // onLoadStop may not fire for BFCache restorations (iOS Safari back
        // gesture), so this ensures the URL bar stays in sync.
        if (url != null) {
          // External-scheme navs (x-safari-https://, intent://) can land a
          // history entry before the cancel takes effect. Persisting one as
          // the site's current URL makes the next launch start on a dead
          // URL that just re-fires the escape redirect.
          if (ExternalUrlParser.parse(url.toString()) != null) return;
          config.onUrlChanged?.call(url.toString());
          // SPA navigations (pushState/replaceState) don't trigger
          // onLoadStart/onLoadStop. Detect by checking if this URL had a
          // corresponding onLoadStart. If not, it's a SPA navigation —
          // re-run user scripts' source code (not the library).
          final urlStr = url.toString();
          if (urlStr != lastLoadStartUrl) {
            userScriptService.reinjectOnSpaNavigation(controller);
          }
          lastLoadStartUrl = null; // Reset for next navigation
        }
      },
      onFindResultReceived: (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        config.onFindResult?.call(activeMatchOrdinal, numberOfMatches);
      },
      onConsoleMessage: (controller, consoleMessage) {
        config.onConsoleMessage?.call(consoleMessage.message, consoleMessage.messageLevel);
      },
      onReceivedError: (controller, request, error) async {
        // An upgrade this engine issued that did not answer: load the original
        // http URL and stop upgrading that host for the rest of the process
        // (HTTPS-002). Ahead of every other recovery below, because those
        // treat the failing URL as the one the site asked for, and this one
        // is not — we substituted it.
        final upgradeFailure = WebViewFactory.httpsUpgrade.onLoadFailed(
            request.url.toString(),
            isMainFrame: request.isForMainFrame ?? true);
        if (upgradeFailure.load != null) {
          LogService.instance.log(
            'WebView',
            'https upgrade did not answer, falling back to '
                '${upgradeFailure.load}',
            sensitivity: LogSensitivity.sensitive,
          );
          controller.loadUrl(urlRequest: inapp.URLRequest(
              url: inapp.WebUri(upgradeFailure.load!)));
          return;
        }
                LogService.instance.log(
          'WebViewLifecycle',
          'onReceivedError siteId=${config.posture.siteId} url=${request.url} '
              'type=${error.type} desc=${error.description}',
          level: LogLevel.warning,
          sensitivity: LogSensitivity.sensitive,
        );
        // For non-internal schemes (intent://, custom app schemes) Android
        // sometimes hands the URL straight to onReceivedError without
        // calling shouldOverrideUrlLoading first — observed every time on
        // Google Maps' window.location='intent://...' redirect. Without
        // routing through the dialog path here, the user never sees the
        // confirmation, suppression is never marked, and the previous
        // "reload lastStableUrl" recovery looped forever (every reload
        // re-renders the page that re-fires the same intent).
        //
        // New flow:
        //   * already suppressed → silent no-op (lets the page sit on
        //     whatever it managed to render before redirecting).
        //   * external scheme + host UI hooked up → fire the dialog
        //     callback; the helper guards against duplicate prompts and
        //     marks suppression on the user's choice.
        //   * external scheme + no host UI → best-effort reload.
        if (request.isForMainFrame != true) return;
        LogService.instance.log(
          'WebViewLifecycle',
          'main-frame load error type=${error.type} ${ProxyManager.stateForLogs}',
          level: LogLevel.warning,
        );
        final reqUrl = request.url.toString();
        // iOS/macOS post-failure TLS path: `_handleServerTrust` deferred
        // to the OS and the OS rejected. Show the user prompt; on
        // approval pin the cached cert and reload.
        if (_isSslError(error.type)) {
          LogService.instance.log(
            'TLS',
            'onReceivedError ssl: type=${error.type} url=$reqUrl description="${error.description}"',
            sensitivity: LogSensitivity.sensitive,
          );
          final handled = await _handleSslLoadError(
            view: view,
            url: reqUrl,
            prompt: config.hooks.untrustedCertificate,
          );
          if (handled) return;
        }
        final externalInfo = ExternalUrlParser.parse(reqUrl);
        if (externalInfo == null) {
          // Ordinary load failure (no external scheme, TLS already handled
          // above). Report it so the host can re-issue the load on the next
          // resume when the cause was the OS cutting the network out from
          // under a backgrounded process — PAUSE-022.
          failedNavUrl = reqUrl;
          config.onMainFrameLoad?.call(
              MainFrameLoadSignal.failed(reqUrl, error.type.toValue()));
          return;
        }
        if (ExternalUrlSuppressor.isSuppressedInfo(externalInfo)) {
          if (!hostIsAndroid) {
            // WebKit reports a policy-cancelled external-scheme nav as
            // error 102 (frame load interrupted) but keeps the committed
            // page painted — loading about:blank here would wipe the page
            // the user is looking at (and clobber a silent-route load the
            // shouldOverrideUrlLoading path just issued). Only Android
            // paints chrome-error:// over the page and needs the clear.
            LogService.instance.log(
              'WebView',
              'onReceivedError: suppressed — committed page intact, no-op (url=$reqUrl)',
              sensitivity: LogSensitivity.sensitive,
            );
            return;
          }
          LogService.instance.log(
            'WebView',
            'onReceivedError: suppressed — loading about:blank to clear error commit (url=$reqUrl)',
            sensitivity: LogSensitivity.sensitive,
          );
          // The fallback page actually loaded (HtmlCache shows
          // multi-MB saves); Android then painted chrome-error://
          // chromewebdata over it because the page's JS retried the
          // intent we cancelled. about:blank clears the error visibly
          // without walking back through history (controller.goBack
          // dropped users out of the webview entirely). The
          // suppression already prevents another dialog if the page
          // tries again.
          Future.microtask(() async {
            await view?.loadUrl('about:blank');
          });
          return;
        }
        final resolved = ExternalUrlParser.toWebUrl(externalInfo);
        if (resolved != null) {
          ExternalUrlSuppressor.mark(externalInfo);
          LogService.instance.log(
            'WebView',
            'onReceivedError: external scheme resolved → $resolved (from $reqUrl)',
            sensitivity: LogSensitivity.sensitive,
          );
          Future.microtask(() async {
            final bool allow =
                config.shouldOverrideUrlLoading?.call(resolved, false) ?? true;
            await view?.loadUrl(allow ? resolved : 'about:blank');
          });
          return;
        }
        // No web equivalent — fall through to the dialog path so the
        // user can still choose to launch the target app.
        LogService.instance.log(
          'WebView',
          'onReceivedError: type=${error.type} url=$reqUrl '
              '— routing to external-scheme dialog',
          sensitivity: LogSensitivity.sensitive,
        );
        config.hooks.externalScheme(externalInfo, view);
      },
      // Header names, never values, and no URL, so the line reaches logcat:
      // the name set tells the app's own proxy relay (`connection` alone, or
      // `proxy-authenticate`) apart from a real server.
      onReceivedHttpError: (controller, request, errorResponse) {
        if (request.isForMainFrame != true) return;
        final headerNames = [
          for (final name in errorResponse.headers?.keys ?? const <String>[])
            name.toLowerCase(),
        ]..sort();
        LogService.instance.log(
          'WebViewLifecycle',
          'main-frame HTTP ${errorResponse.statusCode} '
              'headers=[${headerNames.join(',')}] ${ProxyManager.stateForLogs}',
          level: LogLevel.warning,
        );
      },
      onDownloadStartRequest: (controller, downloadStartRequest) async {
        // onUrlChanged / onUpdateVisitedHistory has likely already fired
        // with the download URL (e.g. "data:application/pdf;..."), which
        // would otherwise be persisted as the site's "current URL" and
        // tried again on next launch. Resolve the revert target BEFORE
        // awaiting the download so a nested callback can't clobber it,
        // then roll the URL bar back after stopLoading().
        final revert = DownloadUrlRevertEngine.pickRevertTarget(
          lastStableUrl: lastStableUrl,
          initialUrl: config.initialUrl,
        );
        // Abort the main-frame navigation to this URL. Without this the
        // webview tries to render the attachment response as a page and ends
        // up on a "net::ERR_UNKNOWN_URL_SCHEME" / "invalid request" error
        // page while the URL bar is stuck on the download URL.
        await view?.stopLoading();
        await _handleDownloadRequest(
          controller,
          downloadStartRequest,
          referer: lastStableUrl ?? config.initialUrl,
          proxy: config.posture.container.proxy,
        );
        if (revert != null) {
          config.onUrlChanged?.call(revert);
        }
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) =>
          _handleServerTrust(view, challenge, config.hooks.untrustedCertificate),
      onReceivedHttpAuthRequest: (controller, challenge) =>
          answerHttpAuthChallenge(
            routerIdentity: _routerIdentityForConfig(config),
            session: httpAuth,
            challenge: challenge,
          ),
      // Android `WebView.onRenderProcessGone`: the OS can kill the renderer
      // process while the app is backgrounded to reclaim memory. Coming back
      // to a renderer-gone WebView shows a black surface because the view is
      // alive but has no renderer driving it. Android docs require the host
      // to destroy and rebuild the WebView — we hand the event up to the
      // owning model, which clears `webview`/`controller` and triggers a
      // setState so the IndexedStack child rebuilds at the same `currentUrl`.
      // Fixes issue #333.
      onRenderProcessGone: (controller, detail) {
        LogService.instance.log(
          'WebView',
          'onRenderProcessGone: siteId=${config.posture.siteId} didCrash=${detail.didCrash} '
              'priority=${detail.rendererPriorityAtExit}',
          level: LogLevel.warning,
        );
        config.onRendererGone?.call(detail.didCrash);
      },
      // iOS/macOS parity for `onRenderProcessGone`: WKWebView raises this
      // when the web content process is killed (OS memory pressure during
      // backgrounding, or a page-induced crash). Same recovery path —
      // throw the WebView away and let the host rebuild.
      onWebContentProcessDidTerminate: (controller) {
        LogService.instance.log(
          'WebView',
          'onWebContentProcessDidTerminate: siteId=${config.posture.siteId}',
          level: LogLevel.warning,
        );
        config.onRendererGone?.call(true);
      },
    );
    final scoped = _ControllerScope(
      key: config.key,
      onUnmount: () => view?._disposed = true,
      child: webViewWidget,
    );
    return _applyLetterbox(config, _applyRefreshGate(config, scoped));
  }

  /// Feeds the raw pointer stream to [WebViewConfig.pullToRefreshGate].
  /// [Listener] never joins the gesture arena, so the webview keeps every
  /// touch it would otherwise receive.
  static Widget _applyRefreshGate(WebViewConfig config, Widget webView) {
    final gate = config.pullToRefreshGate;
    if (gate == null) return webView;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => gate.onPointerDown(event.pointer),
      onPointerUp: (event) => gate.onPointerUp(event.pointer),
      onPointerCancel: (event) => gate.onPointerUp(event.pointer),
      child: webView,
    );
  }

  /// Wrap [webView] in a centered, grid-snapped box with margin bars when the
  /// site has letterboxing on. The InAppWebView instance is reused across
  /// layout changes (rotation re-snaps the box without rebuilding the view),
  /// so the page is not reloaded. When letterboxing is off or the parent is
  /// unbounded, the WebView is returned unwrapped.
  ///
  /// The box is snapped against the extent the body has with the repaint nudge
  /// backed out ([SurfaceNudgeScope]); the nudge's pixel is then taken off the
  /// box rather than the bars, so the platform view still resizes and the bars
  /// hold still.
  static Widget _applyLetterbox(WebViewConfig config, Widget webView) {
    if (!config.posture.fingerprint.letterbox) return webView;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return webView;
        }
        final target = computeLetterboxTarget(
          availableWidth: constraints.maxWidth,
          availableHeight: constraints.maxHeight,
          fixedWidth: config.posture.fingerprint.windowWidth,
          fixedHeight: config.posture.fingerprint.windowHeight,
          transientInsetHeight: SurfaceNudgeScope.bottomInsetOf(context),
        );
        return Container(
          color: const Color(0xFF202124),
          alignment: Alignment.center,
          child: SizedBox(
            width: target.width,
            height: target.height,
            child: webView,
          ),
        );
      },
    );
  }

  /// Cert objects observed via [_handleServerTrust], keyed by host:port.
  /// On iOS/macOS the post-failure prompt fires from `onReceivedError`,
  /// which doesn't carry the cert; we stash whatever the trust callback
  /// saw so the prompt can show subject/issuer/dates.
  static final Map<String, inapp.SslCertificate> _sslCertificateCache = {};

  /// Routes a TLS server-trust challenge.
  ///
  /// Platform contract:
  ///   * iOS/macOS — the upstream plugin fires this for **every** HTTPS
  ///     handshake, not just rejected ones. Returning `null` makes the
  ///     plugin's `nullSuccess` path run, which falls through to
  ///     `URLSession.AuthChallengeDisposition.performDefaultHandling`
  ///     and delegates the verdict to Apple Keychain (system + any CAs
  ///     the user installed). NOTE: `ServerTrustAuthResponse()` looks
  ///     like a no-action response but its Dart constructor defaults
  ///     `action` to `CANCEL`, which silently kills the handshake —
  ///     null is the only way to defer. A genuine failure surfaces via
  ///     `onReceivedError` with a `SERVER_CERTIFICATE_*` error type,
  ///     where the prompt fires and an approved cert is pinned for the
  ///     next attempt.
  ///   * Android & Linux — the underlying signal is already
  ///     post-failure (`WebViewClient.onReceivedSslError` /
  ///     `load-failed-with-tls-errors`), so the callback only runs when
  ///     the OS has rejected the cert. Prompt the user inline.
  static Future<inapp.ServerTrustAuthResponse?> _handleServerTrust(
    WebViewController? view,
    inapp.ServerTrustChallenge challenge,
    Future<bool> Function(String, int, inapp.SslCertificate?)? prompt,
  ) async {
    final space = challenge.protectionSpace;
    final host = space.host;
    // `space.port` is `int?` but on Android the upstream plugin
    // surfaces `-1` (NSURLProtectionSpace sentinel) rather than null,
    // which slips past the `??`. Coalesce any non-positive value to
    // the protocol default. Otherwise pins land as
    // `(host, -1, sha256)` and the dart:io `badCertificateCallback`
    // (which always sees the real socket port, e.g. 443) never
    // matches → favicon stays on the public-CA fallback.
    final rawPort = space.port;
    final port = (rawPort != null && rawPort > 0)
        ? rawPort
        : (space.protocol?.toLowerCase() == 'https' ? 443 : 80);
    final cert = space.sslCertificate;
    final fingerprint = TrustedHostsService.fingerprintFromInappCertificate(cert);
    if (cert != null) {
      _sslCertificateCache[_certCacheKey(host, port)] = cert;
    }
    // Apple: defer to OS unconditionally. The pin store doesn't help
    // here — modern macOS/iOS reject self-signed at the BoringSSL layer
    // before our PROCEED can take effect, and valid public-CA certs
    // are accepted by the OS without consulting the pin store. Pins
    // remain useful for Android post-failure and for dart:io
    // `HttpClient.badCertificateCallback` (favicon fetch, etc.), but
    // querying them in this code path on Apple was log noise at best.
    if (hostIsIOS || hostIsMacOS) {
      return null;
    }
    if (TrustedHostsService.instance.isTrusted(
      host: host,
      port: port,
      fingerprint: fingerprint,
    )) {
      LogService.instance.log(
        'TLS',
        'pinned cert accepted for $host:$port (sha256=$fingerprint)',
        sensitivity: LogSensitivity.sensitive,
      );
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.PROCEED);
    }
    // Loopback sinkhole: a device-level DNS/ad blocker (VPN-based
    // blocker, hosts-file sinkhole, Private DNS, etc.) may resolve a
    // tracker host to 127.0.0.1 where a local responder answers with a
    // self-signed `CN=localhost` cert. The OS rejects it (hostname
    // mismatch + untrusted self-signed) and the trust callback fires
    // per sub-resource, which used to stack a separate "Untrusted
    // certificate" prompt for every blocked ad domain on the page. No
    // user would trust `localhost` for a remote host, so cancel
    // silently — never prompt, never pin. The genuine local-dev case
    // (browsing to `https://localhost`) is preserved because the
    // requested host then matches the cert identity.
    if (_isLoopbackSinkholeCert(host, cert)) {
      LogService.instance.log(
        'TLS',
        'localhost sinkhole cert for $host:$port — cancelling silently '
            '(no prompt; likely a device-level DNS/ad blocker)',
        sensitivity: LogSensitivity.sensitive,
      );
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
    // An upgrade of ours (HTTPS-007). The user asked for http; we substituted
    // https on their behalf, and its certificate did not validate. Prompting
    // here would ask them to judge a connection they never made, about a URL
    // they never typed, and TLS-002's approval PINS the certificate for good.
    // Fall back to the http they actually asked for instead: same shape as the
    // loopback-sinkhole carve-out above, never prompt, never pin.
    final upgradeCert =
        WebViewFactory.httpsUpgrade.onCertificateRejected(host);
    if (upgradeCert.load != null) {
      LogService.instance.log(
        'TLS',
        'untrusted cert on an https upgrade for $host:$port — cancelling '
            'silently and falling back to ${upgradeCert.load} (no prompt, '
            'no pin)',
        sensitivity: LogSensitivity.sensitive,
      );
      view?.loadUrl(upgradeCert.load!);
    }
    if (upgradeCert.cancel) {
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
        // Post-failure platforms (Android, Linux): the OS already rejected
    // the chain. Prompt the user now.
    if (prompt == null) {
      LogService.instance.log(
        'TLS',
        'untrusted cert for $host:$port and no host UI — cancelling load',
        sensitivity: LogSensitivity.sensitive,
      );
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
    final approved = await prompt(host, port, cert);
    if (!approved) {
      LogService.instance.log(
        'TLS',
        'user rejected untrusted cert for $host:$port',
        sensitivity: LogSensitivity.sensitive,
      );
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
    if (fingerprint != null) {
      await TrustedHostsService.instance.trust(
        host: host,
        port: port,
        fingerprint: fingerprint,
      );
      LogService.instance.log(
        'TLS',
        'user trusted cert for $host:$port (pinned sha256=$fingerprint)',
        sensitivity: LogSensitivity.sensitive,
      );
    } else {
      LogService.instance.log(
        'TLS',
        'user trusted cert for $host:$port (no DER from platform — not pinned)',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    // Android's SslErrorHandler (and WPE's TLS-error proxy) may have
    // been invalidated during the async prompt — the WebView gives up
    // on the request long before the user finishes reading the dialog,
    // so handler.proceed() lands on a dead request and the page never
    // paints. Reload re-issues the failed nav; this PROCEED arm
    // short-circuits via the now-matching pin synchronously on the
    // new attempt.
    Future.microtask(() async {
      await view?.reload();
    });
    return inapp.ServerTrustAuthResponse(
        action: inapp.ServerTrustAuthResponseAction.PROCEED);
  }

  static String _certCacheKey(String host, int port) =>
      '${host.toLowerCase()}:$port';

  static bool _isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
  }

  /// True when [cert] is a self-signed `CN=localhost` certificate served
  /// for a non-loopback [host] — the signature of a device-level DNS/ad
  /// sinkhole answering a blocked tracker on `127.0.0.1`. Such a cert is
  /// never something the user means to trust for a remote host, so the
  /// caller cancels the load without prompting. A real `https://localhost`
  /// dev server is excluded because [host] then matches the cert identity.
  static bool _isLoopbackSinkholeCert(String host, inapp.SslCertificate? cert) {
    if (cert == null) return false;
    return isLoopbackSinkholeCert(
      host: host,
      issuedToCName: cert.issuedTo?.CName,
      issuedByCName: cert.issuedBy?.CName,
    );
  }

  /// Pure classification behind [_isLoopbackSinkholeCert], split out so it
  /// can be unit-tested without constructing a plugin `SslCertificate`.
  @visibleForTesting
  static bool isLoopbackSinkholeCert({
    required String host,
    String? issuedToCName,
    String? issuedByCName,
  }) {
    if (_isLoopbackHost(host)) return false;
    final issuedTo = issuedToCName?.trim().toLowerCase();
    final issuedBy = issuedByCName?.trim().toLowerCase();
    return issuedTo == 'localhost' || issuedBy == 'localhost';
  }

  /// Whether [error] indicates the OS rejected the server certificate.
  /// Used by the iOS/macOS post-failure branch in `onReceivedError`.
  static bool _isSslError(inapp.WebResourceErrorType type) {
    return type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_UNTRUSTED ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_HAS_UNKNOWN_ROOT ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_HAS_BAD_DATE ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_NOT_YET_VALID ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_REVOKED ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_BAD_IDENTITY ||
        type == inapp.WebResourceErrorType.SECURE_CONNECTION_FAILED ||
        type == inapp.WebResourceErrorType.FAILED_SSL_HANDSHAKE;
  }

  /// Hosts with an in-flight prompt — guards against the cascade of
  /// duplicate `onReceivedError` calls a single failed nav can fire
  /// (main frame + favicon + service worker probes).
  static final Set<String> _inflightSslPrompts = {};

  /// Hosts we have recently reloaded after a TLS failure when a pin
  /// existed. iOS WKWebView fires `onReceivedError` for every failed
  /// connection even when our async `.useCredential` would have
  /// succeeded — the underlying NSURLSession has already entered a
  /// failed state by the time the trust callback's response arrives.
  /// Reloading kicks off a fresh connection that does see our PROCEED
  /// in time. We need exactly one reload per failure burst, otherwise
  /// the post-reload's own stale `onReceivedError` triggers another
  /// reload, ad infinitum. Time-based: any reload claim within
  /// [_reloadGuardTimeout] of a previous one for the same host is
  /// suppressed. The timeout is the only clear path, so a genuine
  /// new TLS problem at the host (cert rotation, etc.) is allowed
  /// through after the window expires.
  static final Map<String, DateTime> _pendingSslReloads = {};
  static const Duration _reloadGuardTimeout = Duration(seconds: 10);

  static bool _claimReloadGuard(String key) {
    final now = DateTime.now();
    final prev = _pendingSslReloads[key];
    if (prev != null && now.difference(prev) < _reloadGuardTimeout) {
      return false;
    }
    _pendingSslReloads[key] = now;
    return true;
  }

  /// iOS/macOS post-failure path. The trust callback returned `null`
  /// (deferring to OS), the OS rejected, and now we get a chance to
  /// act. Two cases:
  ///   * Cert is already pinned (cached fingerprint matches) — the OS
  ///     rejection was lower-layer (the trust callback's async
  ///     `.useCredential` didn't beat NSURLSession's failure state).
  ///     A fresh reload starts a new connection where our PROCEED
  ///     wins. Guarded so a single nav can only trigger one reload.
  ///   * Not pinned — show the prompt; on approval pin the cached
  ///     cert and reload. The reload's trust callback finds the pin
  ///     and returns PROCEED.
  static Future<bool> _handleSslLoadError({
    required WebViewController? view,
    required String url,
    required Future<bool> Function(String, int, inapp.SslCertificate?)? prompt,
  }) async {
    // Modern Apple platforms (macOS 15+, iOS 26+) reject self-signed
    // certs at the `nw_protocol_boringssl` layer regardless of the
    // app's `URLCredential(trust:)` override. There is no sandboxed-app
    // workaround: `SecTrustSettingsSetTrustSettings` is blocked by the
    // sandbox and Safari uses a private SPI we don't have. Skip the
    // prompt + reload entirely on Apple platforms — both would loop on
    // the same `SECURE_CONNECTION_FAILED`. Public CA-signed sites still
    // load via the normal OS-default path; only self-signed /
    // unknown-CA sites fail closed here. Users can install the cert
    // manually (Keychain Access on macOS, Settings → General →
    // Certificate Trust Settings on iOS).
    if (hostIsMacOS || hostIsIOS) {
      return false;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return false;
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final key = _certCacheKey(host, port);
    final cert = _sslCertificateCache[key];
    final fingerprint =
        TrustedHostsService.fingerprintFromInappCertificate(cert);
    if (TrustedHostsService.instance.isTrusted(
      host: host,
      port: port,
      fingerprint: fingerprint,
    )) {
      if (!_claimReloadGuard(key)) {
        LogService.instance.log(
          'TLS',
          'ignoring further ssl errors for $host:$port — reload already in flight',
          sensitivity: LogSensitivity.sensitive,
        );
        return true;
      }
      LogService.instance.log(
        'TLS',
        'pin matches but iOS reported error for $host:$port — reloading once '
            '(os: $hostOperatingSystem $hostOperatingSystemVersion)',
        sensitivity: LogSensitivity.sensitive,
      );
      Future.microtask(() async {
        await view?.loadUrl(url);
      });
      return true;
    }
    if (prompt == null) return false;
    if (!_inflightSslPrompts.add(key)) return true;
    try {
      final approved = await prompt(host, port, cert);
      if (!approved) {
        LogService.instance.log(
          'TLS',
          'user rejected untrusted cert for $host:$port',
          sensitivity: LogSensitivity.sensitive,
        );
        return false;
      }
      if (fingerprint == null) {
        LogService.instance.log(
          'TLS',
          'user trusted cert for $host:$port but DER missing — cannot pin, load will fail again',
          sensitivity: LogSensitivity.sensitive,
        );
        return false;
      }
      await TrustedHostsService.instance.trust(
        host: host,
        port: port,
        fingerprint: fingerprint,
      );
      LogService.instance.log(
        'TLS',
        'user trusted cert for $host:$port (pinned sha256=$fingerprint) — reloading',
        sensitivity: LogSensitivity.sensitive,
      );
      await view?.loadUrl(url);
      return true;
    } finally {
      _inflightSslPrompts.remove(key);
    }
  }

  static Future<void> _handleDownloadRequest(
    inapp.InAppWebViewController controller,
    inapp.DownloadStartRequest req, {
    String? referer,
    UserProxySettings? proxy,
  }) async {
    final urlStr = req.url.toString();
    final scheme = req.url.scheme.toLowerCase();

    switch (scheme) {
      case 'http':
      case 'https':
        await _handleHttpDownload(controller, req,
            referer: referer, proxy: proxy);
        return;
      case 'data':
        _handleDataDownload(req);
        return;
      case 'blob':
        await _handleBlobDownload(controller, urlStr, req.suggestedFilename);
        return;
      default:
        _showDownloadSnack('Can\'t download $scheme: URL.');
    }
  }

  static Future<void> _handleHttpDownload(
    inapp.InAppWebViewController controller,
    inapp.DownloadStartRequest req, {
    String? referer,
    UserProxySettings? proxy,
  }) async {
    final initialFilename = DownloadEngine.deriveFilename(
      suggested: req.suggestedFilename,
      url: req.url.toString(),
      mimeType: req.mimeType,
    );
    final task = DownloadsService.instance.start(
      filename: initialFilename,
      url: req.url.toString(),
      bytesTotal: req.contentLength > 0 ? req.contentLength : null,
    );
    try {
      // Scope the read to the WebView that started the download. Under the
      // container engine the site's session lives in its own jar; an
      // unscoped read resolves against the default jar, which is empty, so
      // the GET goes out logged-out and an authenticated download comes
      // back 401/403 (DL-003, CONT-006).
      final cookies = await inapp.CookieManager.instance().getCookies(
        url: req.url,
        webViewController: controller,
      );
      final cookieHeader = DownloadEngine.buildCookieHeader(
        cookies.map((c) => MapEntry(c.name, c.value.toString())),
      );
      LogService.instance.log(
        'Download',
        'HTTP download: url=${req.url} cookies=${cookies.length} '
            'ua=${req.userAgent != null} referer=${referer != null}',
        sensitivity: LogSensitivity.sensitive,
      );
      final engine = DownloadEngine(proxy: proxy);
      final result = await engine.fetch(
        url: req.url.toString(),
        cookieHeader: cookieHeader,
        cookieHeaderFor: (uri) async {
          final hop = await inapp.CookieManager.instance().getCookies(
            url: inapp.WebUri(uri.toString()),
            webViewController: controller,
          );
          return DownloadEngine.buildCookieHeader(
            hop.map((c) => MapEntry(c.name, c.value.toString())),
          );
        },
        userAgent: req.userAgent,
        referer: referer,
        suggestedFilename: req.suggestedFilename,
        mimeTypeHint: req.mimeType,
        onProgress: (done, total) => DownloadsService.instance
            .updateProgress(task.id, bytesDone: done, bytesTotal: total),
      );
      task.filename = result.filename;
      final savedPath = await _saveViaPicker(result);
      if (savedPath == null) {
        DownloadsService.instance.cancel(task.id);
      } else {
        DownloadsService.instance.complete(task.id, savedPath: savedPath);
      }
    } on DownloadException catch (e) {
      DownloadsService.instance.fail(task.id, e.message);
    } catch (e, stack) {
      LogService.instance.log(
        'Download',
        'Download error: $e\n$stack',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      DownloadsService.instance.fail(task.id, e.toString());
    }
  }

  static void _handleDataDownload(inapp.DownloadStartRequest req) async {
    final task = DownloadsService.instance.start(
      filename: req.suggestedFilename?.isNotEmpty == true
          ? req.suggestedFilename!
          : 'download',
      url: req.url.toString(),
    );
    try {
      final result = DownloadEngine.decodeDataUri(
        url: req.url.toString(),
        suggestedFilename: req.suggestedFilename,
      );
      task.filename = result.filename;
      DownloadsService.instance.updateProgress(task.id,
          bytesDone: result.bytes.length, bytesTotal: result.bytes.length);
      final savedPath = await _saveViaPicker(result);
      if (savedPath == null) {
        DownloadsService.instance.cancel(task.id);
      } else {
        DownloadsService.instance.complete(task.id, savedPath: savedPath);
      }
    } on DownloadException catch (e) {
      DownloadsService.instance.fail(task.id, e.message);
    } catch (e, stack) {
      LogService.instance.log(
        'Download',
        'Data-URI download error: $e\n$stack',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      DownloadsService.instance.fail(task.id, e.toString());
    }
  }

  static Future<void> _handleBlobDownload(
    inapp.InAppWebViewController controller,
    String blobUrl,
    String? suggestedFilename,
  ) async {
    final task = DownloadsService.instance.start(
      filename: suggestedFilename?.isNotEmpty == true
          ? suggestedFilename!
          : 'download',
      url: blobUrl,
    );
    final script = buildBlobDownloadIife(
      blobUrl: blobUrl,
      taskId: task.id,
      suggestedFilename: suggestedFilename,
    );
    try {
      await controller.evaluateJavascript(source: script);
    } catch (e, stack) {
      LogService.instance.log(
        'Download',
        'Blob download eval error: $e\n$stack',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      DownloadsService.instance.fail(task.id, e.toString());
    }
  }

  static Future<String?> _saveViaPicker(DownloadResult result) async {
    final isMobile = !kIsWeb && (hostIsIOS || hostIsAndroid);
    final outputPath = await FilePicker.saveFile(
      dialogTitle: 'Save download',
      fileName: result.filename,
      bytes: isMobile ? result.bytes : null,
    );
    if (outputPath == null) return null;
    if (!isMobile) {
      await hostWriteBytes(outputPath, result.bytes);
    }
    return outputPath;
  }

  static void _showDownloadSnack(String message) {
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Coerce a JS handler arg to an int. Small integers come back as int
  /// but large ones can arrive as double (JSON number serialization), so
  /// normalize both.
  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
