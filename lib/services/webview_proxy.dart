import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/container_proxy_ledger.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_refused.dart';
import 'package:webspace/services/webview_config.dart';

export 'package:webspace/services/proxy_refused.dart';

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
inapp.ProxySettings? userProxyToInappProxy(UserProxySettings settings) {
  if (settings.type == ProxyType.DEFAULT) return null;
  if (settings.type == ProxyType.TOR) {
    // TOR has no address until the runtime is up. Returning null while it
    // is not is what trips the `proxyUnavailable` fail-closed branch below
    // rather than loading the page over the device IP.
    return switch (expandTorProxy(settings)) {
      TorRouteUp(:final socks) => userProxyToInappProxy(socks),
      TorRouteBlocked() => null,
    };
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
  required SiteId? siteId,
  required bool ownsContainer,
}) {
  // No site id means no row in the route table, and the shared identity
  // belongs to a group this webview is not part of. Routing it there would
  // put it on another site's circuit, so fall back to its own rule.
  if (siteId == null || siteId.isEmpty) return null;
  return routerRelayProxyOf(ProxyRouterEngine.identityFor(
    siteId: siteId,
    ownsContainer: ownsContainer,
  ));
}

/// Whether a site claiming [claimed] must not load: the binding routes its
/// proxy through the relay, and no router runs or is starting (PROXY-013).
bool relayDownFor(UserProxySettings claimed) =>
    claimed.type != ProxyType.DEFAULT &&
    ProxyManager.binding == ProxyBinding.routed &&
    ProxyRouterService.instance.relayDown;

/// The relay rule a store carries to present [identity] (PROXY-026), or
/// null where the proxy is not bound per store or router mode is not running.
inapp.ProxySettings? routerRelayProxyOf(RouterIdentity identity) {
  // Only where the proxy is bound per store (PROXY-027). Under the
  // process-wide binding the router already rides that one rule -- Android's
  // `ProxyController` -- and a per-WebView `proxySettings` there would be a
  // second, conflicting source of truth for the same traffic.
  if (ProxyManager.binding != ProxyBinding.perSite) return null;
  final router = ProxyRouterService.instance;
  if (!router.isActive) return null;
  final host = router.host;
  final port = router.port;
  if (host == null || port == null) return null;
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
  RouterIdentity? identity, {
  required inapp.HttpAuthenticationChallenge challenge,
}) async {
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

/// The identity a site presents to the proxy router (PROXY-013).
///
/// Sites without a container profile share the default profile's cached
/// proxy credential, so they share one identity; see
/// [ProxyRouterEngine.sharedProfileIdentity].
RouterIdentity routerIdentityForConfig(WebViewConfig config) =>
    ProxyRouterEngine.identityFor(
      siteId: config.posture.siteId,
      ownsContainer: config.posture.container.containerId != null,
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
  required Isolation isolation,
  required bool incognito,
}) =>
    isolation is Containers &&
    // Android binds one even under incognito: it has no ephemeral profile,
    // so an unbound site would share the default store with every other
    // such site and leave its storage behind (ARCH-006/ARCH-007). The other
    // platforms short-circuit to an ephemeral store instead, which is a
    // session of its own and needs no name.
    (!incognito || hostIsAndroid);

/// The native container a site's webview binds (`ws-<id>`), or null when it
/// binds none: the legacy engine, or an incognito site off Android, which gets
/// an ephemeral store. Resolved once into the site's posture
/// (`SitePosture.container.containerId`), which the factory binds by and the
/// site info sheet reports.
ContainerName? containerIdFor({
  required Isolation isolation,
  required ContainerKey key,
  required bool incognito,
}) =>
    siteOwnsContainerProfile(isolation: isolation, incognito: incognito)
        ? ContainerName.of(key)
        : null;

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

  /// Whether the process-global override currently names a proxy. Read by
  /// `deferInitialLoadForProxy` so a DEFAULT site built while another site's
  /// proxy is still in force does not issue its first request through it.
  static bool overrideActive = false;

  /// The process-wide proxy state with no address in it, so a failed load
  /// can say whether a proxy was in its path without a sensitive entry.
  static String get stateForLogs => 'proxyOverride=$overrideActive '
      'router=${ProxyRouterService.instance.isActive}';

  static ProxyBinding? _binding;

  /// Where this process enforces a per-site proxy (PROXY-027).
  ///
  /// Latched on first read, so a WebView built under one binding cannot be
  /// driven by another for the rest of the run. The restore decides it
  /// ([decideBinding]) before any site's webview is built; a read before
  /// that takes the host's answer with no per-site profiles.
  static ProxyBinding get binding =>
      _binding ??= _bindingWith(containers: false);

  /// Decides [binding] once the restore knows how sites are kept apart: on
  /// Android, per-site profiles are what let the relay tell sites apart
  /// (PROXY-013), and without them the one rule names a site's own proxy
  /// (PROXY-008).
  static void decideBinding(Isolation isolation) {
    final decided = _bindingWith(containers: isolation is Containers);
    assert(
      _binding == null || _binding == decided,
      'the proxy binding was read as $_binding before the restore decided '
      '$decided (PROXY-013)',
    );
    _binding = decided;
  }

  static ProxyBinding _bindingWith({required bool containers}) =>
      _pinnedForTest ??
      ProxyBindingEngine.bindingWhen(
        isIOS: hostIsIOS,
        isMacOS: hostIsMacOS,
        isLinux: hostIsLinux,
        androidContainers: hostIsAndroid && containers,
      );

  static ProxyBinding? _pinnedForTest;

  /// [binding] whatever the host and the restore say, or theirs again with
  /// null: for a test that runs another binding's paths, as the Android
  /// ones on the Linux or macOS host CI runs Dart tests on.
  @visibleForTesting
  static void pinBindingForTest(ProxyBinding? binding) {
    _pinnedForTest = binding;
    _binding = null;
  }

  /// Containers this process built a WebView on with a proxy (PROXY-029).
  static final ContainerProxyLedger containerProxies = ContainerProxyLedger();

  /// Called wherever a WebView is built with [proxy] on [containerId].
  static void noteStoreProxy(ContainerName? containerId,
          {required inapp.ProxySettings? proxy}) =>
      containerProxies.noteBuild(containerId, proxy: proxy);

  /// Clear [containerId]'s proxy through `ProxyController`, which hands its
  /// WebViews back to the app-wide override or to no proxy. Throws
  /// [ProxyRefused] if the clear fails; the caller keeps the page blank
  /// rather than loading it through the proxy the site gave up.
  Future<void> releaseContainerProxy(ContainerName containerId) async {
    await _platformTakes(() => containerProxies.release(
          containerId,
          clear: (id) => inapp.ProxyController.instance()
              .clearProxyOverride(containerId: id),
        ));
    LogTag.proxy.info(
        'Cleared container proxy for $containerId', sensitive: true);
  }

  /// [siteId] is the isolation tag a TOR proxy carries (TOR-003): without
  /// it every Tor site would present the app-global credential, and the one
  /// rule in force would put them all on one circuit. Where one rule covers
  /// the process, the write is [occupant]'s claim on it ([ProcessRoute]).
  /// Throws [ProxyRefused] for a rule it will not make or the platform did
  /// not take.
  Future<void> setProxySettings(UserProxySettings settings,
          {required SiteId siteId, required RouteOccupant occupant}) =>
      _platformTakes(
          () => _applyRule(settings, siteId: siteId, occupant: occupant));

  /// Runs [call], reporting the plugin's refusal of a rule (its channel
  /// failure, or no plugin) as [ProxyRefused].
  static Future<void> _platformTakes(Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException catch (e, st) {
      Error.throwWithStackTrace(ProxyRefused('$e'), st);
    } on MissingPluginException catch (e, st) {
      Error.throwWithStackTrace(ProxyRefused('$e'), st);
    }
  }

  Future<void> _applyRule(UserProxySettings settings,
      {required SiteId siteId, required RouteOccupant occupant}) async {
    if (!PlatformInfo.isProxySupported) {
      LogTag.proxy.debug(
          'setProxySettings: platform does not support proxy override; no-op',
          sensitive: true);
      return;
    }

    switch (binding) {
      case ProxyBinding.perSite:
        // The proxy travels through the fork's
        // `inapp.InAppWebViewSettings.proxySettings` field at WebView
        // construction, so there is nothing to flip here, and a process-wide
        // override written on Linux would move every session that holds
        // none. Runtime updates of the per-site proxy require the WebView to
        // be rebuilt by the caller (see [WebViewModel.updateProxySettings]).
        LogTag.proxy.debug(
            'setProxySettings: the store binds the proxy at WebView construction; no-op here',
            sensitive: true);
        return;
      case ProxyBinding.routed:
        // Router mode owns the process-wide rule: it points at the loopback
        // relay for every site, and flipping it per activation is exactly
        // the serialisation PROXY-013 removes. Per-site routing is refreshed
        // through `ProxyRouterService`. A proxied site waits for a start in
        // flight and must not load without the relay (PROXY-013).
        final proxied =
            resolveEffectiveProxy(settings, siteId: siteId).type !=
                ProxyType.DEFAULT;
        if (proxied && !await ProxyRouterService.instance.settled) {
          LogTag.proxy.error(
              'Router mode is not running; refusing to load a proxied site '
              'without it', sensitive: true);
          throw const ProxyRefused('the proxy router is not running');
        }
        return;
      case ProxyBinding.processWide:
        break;
    }

    final controller = inapp.ProxyController.instance();

    // When the per-site setting is DEFAULT, fall through to the app-global
    // outbound proxy. This keeps webview traffic and Dart-side traffic
    // honoring the same proxy precedence: explicit per-site override wins,
    // otherwise the global applies, otherwise system/direct.
    UserProxySettings effective =
        resolveEffectiveProxy(settings, siteId: siteId);
    final route = effective.routeKey;
    final viaTor = effective.type == ProxyType.TOR;
    final fellThrough = settings.type == ProxyType.DEFAULT &&
        effective.type != ProxyType.DEFAULT;
    // TOR names no address of its own; the rule has to carry the endpoint
    // the runtime serves and this site's credential, or the leftover manual
    // address a TOR setting keeps (PROXY-010) would be dialled in clear.
    if (effective.type == ProxyType.TOR) {
      switch (expandTorProxy(effective)) {
        case TorRouteUp(:final socks):
          effective = socks;
        case TorRouteBlocked(:final reason):
          LogTag.proxy.error(
              'Tor is not up ($reason); refusing to apply a proxy rule for a '
              'Tor site.',
              sensitive: true);
          throw const ProxyRefused('Tor is not up');
      }
    }

    if (effective.type == ProxyType.DEFAULT) {
      await ProcessRoute.instance.claim(occupant, route: route, write: () async {
        if (hostIsAndroid) await ProxyRelay.instance.stop();
        LogTag.proxy.info(
            'Clearing proxy override (per-site=DEFAULT, no global proxy set)',
            sensitive: true);
        final sw = Stopwatch()..start();
        await controller.clearProxyOverride();
        overrideActive = false;
        LogTag.proxy.info(
            'Cleared proxy override (native call took ${sw.elapsedMilliseconds}ms)',
            sensitive: true);
      });
      return;
    }

    final (host, port) = switch (ProxyAddressParse.of(effective.address)) {
      ProxyAddress(:final host, :final port) => (host, port),
      ProxyAddressMissing() => _refuse(effective,
          why: 'missing address', message: 'Proxy address is required'),
      ProxyAddressMalformed() => _refuse(effective,
          why: 'malformed address (expected host:port)',
          message: 'Proxy address must be in format host:port'),
      ProxyAddressBadPort() => _refuse(effective,
          why: 'port is not 1-65535', message: 'Invalid port number'),
    };

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
    final applied = effective;
    if (hostIsAndroid && applied.hasCredentials) {
      await ProcessRoute.instance.claim(occupant, route: route, write: () async {
        final relay = await ProxyRelay.instance
            .start(applied, answersEarly: viaTor);
        if (relay == null) {
          LogTag.proxy.error(
              'Auth proxy relay failed to start; refusing to fall back to a '
              'direct connection. Effective: ${applied.describeForLogs()}',
              sensitive: true);
          throw const ProxyRefused('Proxy relay failed to start');
        }
        LogTag.proxy.info(
            'Applying Android proxy override via auth relay (upstream scheme=$scheme'
            '${fellThrough ? ', via DEFAULT->global fallthrough' : ''}, '
            'effective: ${applied.describeForLogs()})', sensitive: true);
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
        LogTag.proxy.info(
            'Applied proxy override via relay (native call took ${sw.elapsedMilliseconds}ms, '
            'relay endpoint=${relay.host}:${relay.port})', sensitive: true);
      });
      return;
    }

    final proxyUrl = applied.hasCredentials
        ? '$scheme://${Uri.encodeComponent(applied.username!)}:${Uri.encodeComponent(applied.password!)}@$host:$port'
        : '$scheme://$host:$port';

    await ProcessRoute.instance.claim(occupant, route: route, write: () async {
      // No credentials (or Linux): point ProxyController straight at the
      // upstream. Stop any relay left over from a previous credentialed
      // config so its loopback port isn't left listening.
      if (hostIsAndroid) await ProxyRelay.instance.stop();
      LogTag.proxy.info('Applying proxy override (scheme=$scheme'
          '${fellThrough ? ', via DEFAULT->global fallthrough' : ''}, '
          'effective: ${applied.describeForLogs()})', sensitive: true);
      final sw = Stopwatch()..start();
      await controller.setProxyOverride(
        settings: inapp.ProxySettings(
          proxyRules: [inapp.ProxyRule(url: proxyUrl)],
          bypassRules: [],
        ),
      );
      overrideActive = true;
      LogTag.proxy.info(
          'Applied proxy override (native call took ${sw.elapsedMilliseconds}ms, '
          'scheme=$scheme)', sensitive: true);
    });
  }

  /// Logs why [effective] cannot be applied and throws, so no rule is
  /// written for it (LEAK-003).
  static Never _refuse(UserProxySettings effective,
      {required String why, required String message}) {
    LogTag.proxy.error(
        'Effective proxy $why; aborting setProxyOverride. '
        'Effective: ${effective.describeForLogs()}', sensitive: true);
    throw ProxyRefused(message);
  }

  /// Point the process-wide rule at the loopback router on [host]:[port]
  /// and leave it there (PROXY-013). The host is the random 127/8 address
  /// the relay bound, not `127.0.0.1`.
  ///
  /// Returns false if the override could not be applied, in which case
  /// the caller MUST NOT treat router mode as active — every site would
  /// otherwise go direct while believing it was proxied.
  Future<bool> applyRouterOverride(String host, {required int port}) async {
    if (!hostIsAndroid || !PlatformInfo.isProxySupported) return false;
    try {
      await inapp.ProxyController.instance().setProxyOverride(
        settings: inapp.ProxySettings(
          proxyRules: [inapp.ProxyRule(url: 'http://$host:$port')],
          bypassRules: [],
        ),
      );
      LogTag.proxy.info(
          'Applied router override -> $host:$port', sensitive: true);
      return true;
    } on PlatformException catch (e) {
      LogTag.proxy.error(
          'Router override failed to apply: $e', sensitive: true);
      return false;
    } on MissingPluginException catch (e) {
      LogTag.proxy.error(
          'Router override failed to apply: $e', sensitive: true);
      return false;
    }
  }

  /// Take the process-wide rule off a relay whose start failed, so a site
  /// with no proxy goes direct (PROXY-013). A rule that will not clear is
  /// logged: every site then fails on the stopped relay, which leaks
  /// nothing.
  Future<void> clearRouterOverride() async {
    if (!hostIsAndroid || !PlatformInfo.isProxySupported) return;
    try {
      await inapp.ProxyController.instance().clearProxyOverride();
      LogTag.proxy.info('Cleared the router override');
    } on PlatformException catch (e) {
      LogTag.proxy.error('Router override failed to clear: $e',
          sensitive: true);
    } on MissingPluginException catch (e) {
      LogTag.proxy.error('Router override failed to clear: $e',
          sensitive: true);
    }
  }
}

/// Android's process-wide rule as router mode drives it (PROXY-013).
final class ProcessRouterOverride implements ProxyRouterOverride {
  const ProcessRouterOverride();

  @override
  Future<bool> bind(String host, {required int port}) =>
      ProxyManager().applyRouterOverride(host, port: port);

  @override
  Future<void> clear() => ProxyManager().clearRouterOverride();
}

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
          appleOsMeetsFloor(hostOperatingSystemVersion,
              isIOS: hostIsIOS, floor: AppleOsFloor.stores);
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
    } on PlatformException {
      _isProxySupportedCached = false;
    } on MissingPluginException {
      _isProxySupportedCached = false;
    }
  }

  static bool get isProxySupported => _isProxySupportedCached ?? false;
}
