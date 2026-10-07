import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/mock_cookie_manager.dart';
import 'helpers/retention_tiers.dart';

WebViewModel _site(String url, {UserProxySettings? proxy}) =>
    WebViewModel(initUrl: url, proxySettings: proxy);

/// One site per proxy, on `a.example.com`, `b.example.com`... or [hosts].
List<WebViewModel> _sites(List<UserProxySettings?> proxies,
        [List<String>? hosts]) =>
    [
      for (var i = 0; i < proxies.length; i++)
        _site('https://${hosts?[i] ?? String.fromCharCode(0x61 + i)}.example.com',
            proxy: proxies[i]),
    ];

UserProxySettings _http(String address) =>
    UserProxySettings(type: ProxyType.HTTP, address: address);
UserProxySettings _socks(String address) =>
    UserProxySettings(type: ProxyType.SOCKS5, address: address);
UserProxySettings _tor([String? country]) =>
    UserProxySettings(type: ProxyType.TOR, torExitCountry: country);
UserProxySettings _default() => UserProxySettings(type: ProxyType.DEFAULT);

/// The topologies a host produces, built the way the app builds them.
final _perSession = ProxyTopology.of(
    linux: false, android: false, routerActive: false,
    sharesDefaultSession: (_) => false);
final _processGlobal = ProxyTopology.of(
    linux: false, android: true, routerActive: false,
    sharesDefaultSession: (_) => false);
ProxyTopology _routed(bool Function(WebViewModel model) sharesDefaultSession) =>
    ProxyTopology.of(
        linux: false, android: true, routerActive: true,
        sharesDefaultSession: sharesDefaultSession);

/// A page under containers unless [sharedJar] is set. The legacy unload is
/// exercised against the real jar engine in
/// cookie_isolation_integration_test.dart.
class _ContainerPage implements ResidencyHost {
  _ContainerPage(this.models) : loadedIndices = {for (var i = 0; i < models.length; i++) i};

  @override
  final List<WebViewModel> models;
  @override
  final Set<int> loadedIndices;
  @override
  CookieIsolationEngine? sharedJar;

  @override
  ProxyTopology proxyTopology = _perSession;
  @override
  bool torAvailable = false;
  SiteRetentionResolver retention = tiers();

  /// Slot -> the site it runs as, for slots showing a hosted tab.
  final Map<int, WebViewModel> hosted = {};

  @override
  List<WebViewModel> identities({int? except}) => [
        for (var i = 0; i < models.length; i++)
          i == except ? models[i] : hosted[i] ?? models[i],
      ];

  @override
  SiteRetentionPriority priorityOf(int index) => retention(index);

  final List<WebViewModel> captured = [];
  final List<(WebViewModel, UnloadReason)> noted = [];

  /// Runs during the capture await, as a concurrent handler would.
  void Function()? duringCapture;

  @override
  Future<void> captureNavState(WebViewModel model) async {
    captured.add(model);
    duringCapture?.call();
  }

  @override
  void noteUnloaded(WebViewModel model, UnloadReason reason) =>
      noted.add((model, reason));
}

void main() {
  setUp(() {
    GlobalOutboundProxy.resetForTest();
  });

  group('SiteUnloadEngine.unload', () {
    for (final reason in UnloadReason.values) {
      test('${reason.name} unloads, logs, and keeps the back stack '
          'unless the site is going home', () async {
        final a = _site('https://a.example.com');
        final page = _ContainerPage([a, _site('https://b.example.com')]);

        await SiteUnloadEngine.unload(page, 0, reason);

        expect(page.loadedIndices, {1});
        expect(page.noted, [(a, reason)]);
        expect(page.captured, reason == UnloadReason.homeReset ? isEmpty : [a]);
      });
    }

    test('unloads the site it was asked for after the list shifts', () async {
      final a = _site('https://a.example.com');
      final b = _site('https://b.example.com');
      final page = _ContainerPage([a, b]);
      page.duringCapture = () => page.models.removeAt(0);

      await SiteUnloadEngine.unload(page, 1, UnloadReason.loadedSiteCap);

      expect(page.noted.single.$1, b);
      expect(page.loadedIndices, isNot(contains(0)),
          reason: 'b moved to index 0 while its state was captured');
    });

    test('every unload in the page goes through the funnel', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, isNot(contains('_cookieIsolation.unloadSiteForDomainSwitch(')));
      final select = main.substring(main.indexOf('void _selectWebspace('));
      expect(select.substring(0, select.indexOf('\n  }\n')),
          contains('_residencyPlan(WebspaceSwitched('));
    });
  });

  group('SiteUnloadEngine.plan', () {
    List<WebViewModel> sites(int n) =>
        [for (var i = 0; i < n; i++) _site('https://s$i.example.com')];
    List<(WebViewModel, UnloadReason)> unloads(ResidencyPlan plan) =>
        [for (final u in plan.unloads) (u.site, u.reason)];
    CookieIsolationEngine jar() => CookieIsolationEngine(
        cookieManager: MockCookieManager(), storage: MockCookieSecureStorage());

    test('activation unloads a same-base-domain site only with a shared jar',
        () {
      final a = _site('https://mail.example.com');
      final b = _site('https://docs.example.com');
      final page = _ContainerPage([a, b])..loadedIndices.remove(1);
      expect(SiteUnloadEngine.plan(page, const Activating(1)).isEmpty, isTrue,
          reason: 'containers keep same-base-domain sites apart (CONT-003)');

      page.sharedJar = jar();
      expect(unloads(SiteUnloadEngine.plan(page, const Activating(1))),
          [(a, UnloadReason.domainConflict)]);
    });

    test('activation runs conflict, proxy, Tor, then the cap, each on what '
        'the rule before left', () {
      final models =
          _sites([_http('p1:8080'), _tor('de'), null, _tor('nl')]);
      final page = _ContainerPage(models)
        ..proxyTopology = _processGlobal
        ..torAvailable = true
        ..loadedIndices.remove(3);
      final plan = SiteUnloadEngine.plan(page, const Activating(3));
      // Every loaded site disagrees with d's proxy; the Tor rule finds none
      // left to take, and the cap counts what remains.
      expect(unloads(plan), [
        (models[0], UnloadReason.proxyMismatch),
        (models[1], UnloadReason.proxyMismatch),
        (models[2], UnloadReason.proxyMismatch),
      ]);
    });

    test('activation reads what each slot runs as (LIR-024)', () {
      final models = _sites([null, _http('p1:8080')]);
      final page = _ContainerPage(models)
        ..proxyTopology = _processGlobal
        ..loadedIndices.remove(1);
      expect(unloads(SiteUnloadEngine.plan(page, const Activating(1))),
          [(models[0], UnloadReason.proxyMismatch)]);
      page.hosted[0] = models[1];
      expect(SiteUnloadEngine.plan(page, const Activating(1)).isEmpty, isTrue,
          reason: 'slot 0 runs as b, so it already shares b\'s proxy');
    });

    test('a Tor exit disagreement unloads only where a Tor runtime exists', () {
      final models = _sites([_tor('de'), _tor('nl')]);
      final page = _ContainerPage(models)..loadedIndices.remove(1);
      expect(SiteUnloadEngine.plan(page, const Activating(1)).isEmpty, isTrue);
      page.torAvailable = true;
      expect(unloads(SiteUnloadEngine.plan(page, const Activating(1))),
          [(models[0], UnloadReason.torExitMismatch)]);
    });

    test('activation evicts past the loaded-site cap, protected sites kept',
        () {
      final models = sites(kMaxLoadedSites + 1);
      final page = _ContainerPage(models)
        ..loadedIndices.remove(kMaxLoadedSites)
        ..retention = tiers(active: {0});
      final plan = SiteUnloadEngine.plan(page, Activating(kMaxLoadedSites));
      expect(unloads(plan), [(models[1], UnloadReason.loadedSiteCap)]);
    });

    test('activation drops the oldest residents past the resident cap', () {
      final models = sites(kMaxResidentSites + 2);
      final target = kMaxResidentSites + 1;
      final page = _ContainerPage(models)
        ..retention = tiers(active: {target});
      models[0].lifecycleState = SiteLifecycleState.cacheCleared;
      final plan = SiteUnloadEngine.plan(page, Activating(target));
      expect(plan.unloads, isEmpty);
      expect(plan.cacheClears, [models[1]],
          reason: 'site 0 is already cleared and does not count');
    });

    test('memory pressure moves one site one tier, never a protected one', () {
      final models = sites(3);
      final page = _ContainerPage(models)..retention = tiers(active: {0});
      expect(SiteUnloadEngine.plan(page, const MemoryPressure()).cacheClears,
          [models[1]]);
      models[1].lifecycleState = SiteLifecycleState.cacheCleared;
      models[2].lifecycleState = SiteLifecycleState.cacheCleared;
      expect(unloads(SiteUnloadEngine.plan(page, const MemoryPressure())),
          [(models[1], UnloadReason.memoryPressure)]);
      page.loadedIndices.removeAll({1, 2});
      expect(SiteUnloadEngine.plan(page, const MemoryPressure()).isEmpty,
          isTrue);
    });

    test('a webspace switch unloads only with a shared jar', () {
      final models = sites(3);
      final page = _ContainerPage(models);
      const event = WebspaceSwitched(previous: {0, 1}, next: {1, 2});
      expect(SiteUnloadEngine.plan(page, event).isEmpty, isTrue);
      page.sharedJar = jar();
      expect(unloads(SiteUnloadEngine.plan(page, event)),
          [(models[0], UnloadReason.webspaceSwitch)]);
    });

    test('a settled Tor exit keeps the first Tor site in order and its '
        'agreeing siblings', () {
      final models = _sites([_tor('de'), null, _tor('nl'), _tor('nl')]);
      final page = _ContainerPage(models)..torAvailable = true;
      expect(unloads(SiteUnloadEngine.plan(page, const TorExitSettled([1, 2, 0, 3]))),
          [(models[0], UnloadReason.torExitMismatch)]);
    });

    test('a nested open reads its own slot as the target itself', () {
      final models = _sites([null, _http('p1:8080')]);
      final page = _ContainerPage(models)
        ..proxyTopology = _processGlobal
        ..hosted[1] = models[0];
      expect(unloads(SiteUnloadEngine.plan(page, const NestedOpening(1))),
          [(models[0], UnloadReason.proxyMismatch)]);
      expect(SiteUnloadEngine.plan(page, const SlotIdentityChanged(1)).isEmpty,
          isTrue, reason: 'on screen, slot 1 runs as a');
    });
  });

  group('SiteUnloadEngine.apply', () {
    test('follows each site across a shift and skips one already gone',
        () async {
      final models = _sites([null, null, null]);
      final page = _ContainerPage(List.of(models));
      final plan = ResidencyPlan(unloads: [
        (site: models[1], reason: UnloadReason.loadedSiteCap),
        (site: models[2], reason: UnloadReason.loadedSiteCap),
      ]);
      page.duringCapture = () {
        page.duringCapture = null;
        page.models.removeAt(0);
        page.loadedIndices
          ..clear()
          ..addAll({0, 1});
      };
      page.loadedIndices.remove(2);
      expect(await SiteUnloadEngine.apply(page, plan, isStale: () => false),
          isTrue);
      expect(page.noted.map((n) => n.$1), [models[1], models[2]]);
      expect(page.loadedIndices, isEmpty);
    });

    test('stops at the first stale await', () async {
      final models = _sites([null, null]);
      final page = _ContainerPage(models);
      final plan = ResidencyPlan(unloads: [
        for (final m in models) (site: m, reason: UnloadReason.proxyMismatch),
      ]);
      expect(await SiteUnloadEngine.apply(page, plan, isStale: () => true),
          isFalse);
      expect(page.noted.single.$1, models[0]);
    });

    test('clears only a site still loaded and resident', () async {
      final models = _sites([null, null]);
      final page = _ContainerPage(models)..loadedIndices.remove(1);
      await SiteUnloadEngine.apply(
        page,
        ResidencyPlan(cacheClears: models),
        isStale: () => false,
      );
      expect(models[0].lifecycleState, SiteLifecycleState.cacheCleared);
      expect(models[1].lifecycleState, SiteLifecycleState.resident);
    });
  });

  group('SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch', () {
    for (final c in [
      (name: 'returns empty under container mode (sites stay resident)',
          containers: true, loaded: {0, 1, 2}, previous: {0, 1}, next: {2, 3},
          unloads: isEmpty),
      // Worst case for legacy (every loaded site leaves the visible set);
      // container mode still keeps them all.
      (name: 'container mode short-circuits even with no overlap',
          containers: true, loaded: {0, 1, 2}, previous: {0, 1, 2},
          next: {3, 4, 5}, unloads: isEmpty),
      (name: 'legacy mode unloads sites visible only in previous webspace',
          containers: false, loaded: {0, 1, 2}, previous: {0, 1}, next: {2, 3},
          unloads: {0, 1}),
      (name: 'legacy mode preserves sites visible in both webspaces',
          containers: false, loaded: {0, 1, 2}, previous: {0, 1, 2},
          next: {1, 2, 3}, unloads: {0}),
      (name: 'legacy mode no-op when no loaded sites in previous webspace',
          containers: false, loaded: {5, 6}, previous: {0, 1}, next: {2, 3},
          unloads: isEmpty),
      (name: 'legacy mode no-op on empty loadedIndices',
          containers: false, loaded: <int>{}, previous: {0, 1, 2},
          next: {3, 4}, unloads: isEmpty),
    ]) {
      test(c.name, () {
        expect(
          SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
            useContainers: c.containers,
            loadedIndices: c.loaded,
            previousWebspaceIndices: c.previous,
            newWebspaceIndices: c.next,
          ),
          c.unloads,
        );
      });
    }
  });

  group('ProxyTopology.of (PROXY-008, PROXY-013)', () {
    ProxyTopology of({bool linux = false, bool android = false, bool router = false}) =>
        ProxyTopology.of(
            linux: linux, android: android, routerActive: router,
            sharesDefaultSession: (_) => false);

    test('Linux is process-global, router or not', () {
      expect(of(linux: true), isA<ProcessGlobalProxy>());
      expect(of(linux: true, router: true), isA<ProcessGlobalProxy>());
    });

    test('Android is process-global until the router runs', () {
      expect(of(android: true), isA<ProcessGlobalProxy>());
      expect(of(android: true, router: true), isA<RoutedProxy>());
    });

    test('iOS and macOS bind per session', () {
      expect(of(), isA<PerSessionProxy>());
    });
  });

  group('SiteUnloadEngine.indicesToUnloadForProxyMismatch', () {
    /// Every site loaded and the topology process-global unless given.
    Set<int> mismatch(List<WebViewModel> models, int target,
            {Set<int>? loaded, ProxyTopology? topology}) =>
        SiteUnloadEngine.indicesToUnloadForProxyMismatch(
          targetIndex: target,
          models: models,
          loadedIndices: loaded ?? {for (var i = 0; i < models.length; i++) i},
          topology: topology ?? _processGlobal,
        );

    /// A process-global case activating [target] among sites a, b, c...
    void unloads(String name, List<UserProxySettings?> proxies, int target,
            Object expected, {UserProxySettings? global}) =>
        test(name, () {
          if (global != null) GlobalOutboundProxy.setForTest(global);
          expect(mismatch(_sites(proxies), target), expected);
        });
    UserProxySettings creds(String username, String password) =>
        UserProxySettings(
            type: ProxyType.HTTP,
            address: 'p:8080',
            username: username,
            password: password);

    // Each Tor site's isolation is its own SOCKS credential. The one rule
    // in force carries one credential, so a Tor site left loaded beside
    // another would ride the other's circuit.
    unloads('two Tor sites never share the one process-wide rule (TOR-025)',
        [_tor(), _tor()], 1, {0});

    // PROXY-011: inheriting the app's Tor is not a request for a circuit
    // of one's own, so these agree and stay loaded together.
    unloads('sites inheriting a global Tor share the app-global circuit',
        [null, null], 1, isEmpty, global: _tor());

    test('returns empty when proxy is per-site (iOS/macOS)', () {
      expect(
          mismatch(_sites([_http('p1:8080'), _socks('p2:9050')]), 1,
              topology: _perSession),
          isEmpty);
    });

    test('router mode still serialises sites that share the default profile',
        () {
      // The concurrency PROXY-013 buys is bought by the per-site container
      // profile: its own Chromium network session, its own cached proxy
      // credential. A site the app cannot bind to one -- incognito, and
      // archive-tier which is always incognito -- runs in the default
      // profile alongside every other such site, so they share the single
      // credential that session caches. Left co-loaded with different
      // proxies, whichever authenticated first routes the rest, silently.
      final models =
          _sites([_socks('p1:9050'), _http('p2:8080'), _http('p2:8080')]);
      expect(mismatch(models, 0, topology: _routed((_) => true)), {1, 2},
          reason: 'both disagree with the activated site and share its '
              'session, so both must go');
    });

    List<WebViewModel> incognitoAndNormal() =>
        _sites([_socks('p1:9050'), _http('p2:8080')], ['incognito', 'normal']);

    test('a container-bound sibling is untouched by that serialisation', () {
      final models = incognitoAndNormal();
      // Only index 0 lives in the default profile.
      expect(mismatch(models, 0, topology: _routed((m) => m == models[0])),
          isEmpty,
          reason: 'the container-bound site has its own session and its own '
              'cached credential, so it is not in the conflict');
    });

    test('activating a container-bound site evicts nothing', () {
      final models = incognitoAndNormal();
      expect(mismatch(models, 1, topology: _routed((m) => m == models[0])),
          isEmpty);
    });

    test('router mode keeps two same-domain sites with different proxies loaded',
        () {
      // PROXY-013. The case PROXY-008 could not serve: two accounts on one
      // service, each meant to be seen from its own exit IP. Under router
      // mode the process-wide rule points at the loopback router and stays
      // there, so activating one must not evict the other -- evicting it is
      // exactly the cold-start cost the router removes.
      final models = _sites(
          [_socks('127.0.0.1:9050'), _http('p2:8080'), _default()],
          ['accountA', 'accountB', 'accountC']);
      for (var target = 0; target < models.length; target++) {
        // Every site here owns its container profile.
        expect(mismatch(models, target, topology: _routed((_) => false)),
            isEmpty,
            reason: 'activating site $target must not evict its siblings');
      }
    });

    // Activating index 1 (SOCKS5) — index 0 (HTTP p1) and index 2 (HTTP p1)
    // must be unloaded; their next request would silently route through
    // p2 once `ProxyController.setProxyOverride` lands the new override.
    unloads('flags loaded sites with a different proxy on Android',
        [_http('p1:8080'), _socks('p2:9050'), _http('p1:8080')], 1, {0, 2});
    unloads('does not flag the activating site itself', [_http('p1:8080')], 0,
        isEmpty);
    unloads('does not flag sites with the same proxy',
        [_http('p1:8080'), _http('p1:8080')], 0, isEmpty);
    // Both fall through resolveEffectiveProxy to the global outbound
    // proxy, so they resolve to the same effective value.
    unloads('two DEFAULT sites are equivalent regardless of global proxy',
        [_default(), _default()], 1, isEmpty,
        global: _socks('tor:9050'));
    unloads('DEFAULT vs explicit-matching-global is equivalent',
        [_default(), _http('gp:1234')], 0, isEmpty,
        global: _http('gp:1234'));
    unloads('flags credential-only differences',
        [creds('alice', 'a-pw'), creds('bob', 'b-pw')], 1, {0});
    // Same host:port string but different protocol — the wire format
    // is fundamentally different (CONNECT tunnel vs SOCKS handshake),
    // so a request that thinks it's going to one will fail on the
    // other. Must be treated as a mismatch.
    unloads('flags type-only differences (HTTP vs SOCKS5, same address)',
        [_http('p:9050'), _socks('p:9050')], 1, {0});
    unloads('flags HTTP vs HTTPS (different schemes)', [
      _http('p:8080'),
      UserProxySettings(type: ProxyType.HTTPS, address: 'p:8080'),
    ], 1, {0});
    unloads('flags address-only differences (host)',
        [_http('p1:8080'), _http('p2:8080')], 1, {0});
    unloads('flags address-only differences (port)',
        [_http('p:8080'), _http('p:9090')], 1, {0});
    unloads('flags username-only differences',
        [creds('alice', 'shared-pw'), creds('bob', 'shared-pw')], 1, {0});
    unloads('flags password-only differences',
        [creds('shared', 'pw1'), creds('shared', 'pw2')], 1, {0});
    // Both sites: same type/address, no credentials. Different
    // construction paths (UserProxySettings(...) vs default ctor) but
    // the field values match.
    unloads('null and absent credentials are equivalent', [
      UserProxySettings(
          type: ProxyType.HTTP, address: 'p:8080', username: null, password: null),
      _http('p:8080'),
    ], 1, isEmpty);
    // Site 0 = DEFAULT → resolves through global (HTTP gp:1234).
    // Site 1 = explicit SOCKS5. Different effective proxy.
    unloads('flags DEFAULT vs explicit-non-matching-global',
        [_default(), _socks('tor:9050')], 1, {0},
        global: _http('gp:1234'));
    // Mix: site 0 matches target, site 2 differs. Activating target
    // (index 1) should unload only 2, not 0.
    unloads('only conflicting indices are returned, not all loaded',
        [_http('p:8080'), _http('p:8080'), _socks('tor:9050')], 1, {2});

    test('skips out-of-bounds entries in loadedIndices', () {
      // Mock state where _loadedIndices contains a stale index past
      // the end of models (e.g. mid-deletion race). Engine must not
      // throw a RangeError.
      expect(mismatch(_sites([_http('p:8080')]), 0, loaded: {0, 99, -1}),
          isEmpty);
    });

    unloads('out-of-bounds target returns empty', [], 5, isEmpty);
    unloads('negative target returns empty', [_http('p:8080')], -1, isEmpty);
  });

  group('SiteUnloadEngine.indicesToUnloadForTorExitMismatch', () {
    Set<int> mismatch(List<WebViewModel> models, int target, Set<int> loaded) =>
        SiteUnloadEngine.indicesToUnloadForTorExitMismatch(
            targetIndex: target, models: models, loadedIndices: loaded);

    /// Activates [target] among sites a, b, c... with all of them loaded
    /// unless [loaded] says otherwise.
    void unloads(String name, List<UserProxySettings?> proxies, int target,
            Object expected, {Set<int>? loaded}) =>
        test(name, () {
          final models = _sites(proxies);
          expect(
              mismatch(models, target,
                  loaded ?? {for (var i = 0; i < models.length; i++) i}),
              expected);
        });

    unloads('flags a loaded site pinned to a different country',
        [_tor('de'), _tor('nl')], 1, {0});
    unloads('leaves sites sharing a country loaded', [_tor('de'), _tor('de')],
        1, isEmpty);
    // The pin is compared as tor's `ExitNodes` value, not as the raw
    // string the user typed, so "DE" and "de " are the same country and
    // must not evict each other.
    unloads('country matching ignores case and surrounding whitespace',
        [_tor('DE'), _tor(' de ')], 1, isEmpty);
    // "No pin" means "must be unrestricted", not "no opinion": there is
    // one global ExitNodes, so leaving the pinned site loaded would keep
    // routing the unpinned site through Germany (TOR-014).
    unloads('an unpinned Tor site evicts a pinned one', [_tor('de'), _tor()], 1,
        {0});
    unloads('a pinned Tor site evicts an unpinned one', [_tor(), _tor('de')], 1,
        {0});
    unloads('two unpinned Tor sites coexist', [_tor(), _tor()], 1, isEmpty);

    test('a malformed country is treated as unpinned, not as its own pin', () {
      // It never reaches SETCONF (exitNodesValue drops it), so a site
      // carrying one is unrestricted and must conflict like any other
      // unpinned site rather than forming a third bucket of its own.
      final models = _sites([_tor('deutschland'), _tor(), _tor('de')]);
      expect(mismatch(models, 1, {0, 1}), isEmpty);
      expect(mismatch(models, 2, {0, 2}), {0});
    });

    test('a non-Tor site neither evicts nor is evicted', () {
      // ExitNodes says nothing about where a SOCKS5 site's traffic goes.
      final models = _sites([_tor('de'), _socks('p:9')]);
      expect(mismatch(models, 1, {0, 1}), isEmpty);
      expect(mismatch(models, 0, {0, 1}), isEmpty);
    });

    unloads('a country left over on a site since switched away is inert', [
      _tor(),
      UserProxySettings(
          type: ProxyType.SOCKS5, address: 'p:9', torExitCountry: 'nl'),
    ], 0, isEmpty);

    test('a DEFAULT site inherits the global pin rather than reading as unpinned', () {
      GlobalOutboundProxy.setForTest(_tor('de'));
      addTearDown(GlobalOutboundProxy.resetForTest);
      final models = _sites([_tor('de'), _default(), _tor('nl')]);
      expect(mismatch(models, 1, {0, 1}), isEmpty,
          reason: 'it inherits {de}, which is what site A already holds');
      expect(mismatch(models, 1, {1, 2}), {2},
          reason: 'inheriting {de} conflicts with {nl} like any other pin');
    });

    test('a DEFAULT site under a non-Tor global is unaffected', () {
      GlobalOutboundProxy.setForTest(_http('p:8080'));
      addTearDown(GlobalOutboundProxy.resetForTest);
      expect(mismatch(_sites([_tor('de'), _default()]), 1, {0, 1}), isEmpty);
    });

    unloads('does not flag the activating site itself', [_tor('de')], 0,
        isEmpty);
    unloads('ignores unloaded sites', [_tor('de'), _tor('nl')], 1, isEmpty,
        loaded: {1});

    test('the pin in force follows the loaded set', () {
      final models = _sites([_tor('de'), _tor(), _socks('p:9')]);
      String? nodes(Set<int> indices) =>
          SiteUnloadEngine.torExitNodesFor(indices: indices, models: models);
      expect(nodes({0}), '{de}');
      expect(nodes({1}), isNull,
          reason: 'an unpinned Tor site wants ExitNodes cleared, not left set');
      expect(nodes({2}), isNull);
      expect(nodes(const <int>{}), isNull);
    });

    test('a saved pin change unloads the loaded site it now disagrees with',
        () {
      // From a device: site 1 was moved to Canada in its settings while
      // site 0, pinned to Denmark, was loaded. The pin went to {ca} and site
      // 0 was rebuilt under it once Tor came back up. The site on screen is
      // the anchor; everything loaded that disagrees with it goes first.
      final models = _sites([_tor('dk'), _tor('ca'), _socks('p:9')]);
      final order = <int>{1, 0, 2};
      final anchor =
          SiteUnloadEngine.torExitAnchor(indices: order, models: models);
      expect(anchor, 1);
      expect(mismatch(models, anchor!, {0, 1, 2}), {0});
      expect(SiteUnloadEngine.torExitNodesFor(indices: order, models: models),
          '{ca}');
    });

    test('with a non-Tor site on screen, the first Tor site in order anchors',
        () {
      final models = _sites([_socks('p:9'), _tor('dk'), _tor()]);
      expect(
          SiteUnloadEngine.torExitAnchor(indices: {0, 2, 1}, models: models), 2);
      expect(SiteUnloadEngine.torExitAnchor(indices: {0}, models: models),
          isNull);
    });

    test('a non-Tor site does not mask the pin a loaded Tor site holds', () {
      // Activating a SOCKS5 site evicts nobody, so the pinned site is still
      // loaded and the pin must survive the reconciliation.
      final models = _sites([_socks('p:9'), _tor('de')]);
      expect(
        SiteUnloadEngine.torExitNodesFor(indices: {0, 1}, models: models),
        '{de}',
      );
    });

    test('a pin only archived sites want may not download GeoIP', () {
      // ARCH-006: the table would be a trace outside the archive.
      final models = _sites([_tor('de'), _tor('de'), null]);
      models[0].isArchiveTier = true;
      bool archiveOnly(Set<int> indices) =>
          SiteUnloadEngine.torExitPinIsArchiveOnly(
              indices: indices, models: models);
      expect(archiveOnly({0}), isTrue);
      expect(archiveOnly({0, 2}), isTrue,
          reason: 'a site not on Tor has no say in the pin');
      expect(archiveOnly({0, 1}), isFalse);
      expect(archiveOnly({2}), isFalse);
    });

    test('the pin ignores out-of-range indices', () {
      final models = _sites([_tor('de')]);
      expect(
        SiteUnloadEngine.torExitNodesFor(indices: {-1, 9, 0}, models: models),
        '{de}',
      );
    });

    test('tolerates out-of-range indices', () {
      final models = _sites([_tor('de')]);
      expect(mismatch(models, -1, {0}), isEmpty);
      expect(mismatch(models, 5, {0}), isEmpty);
      expect(mismatch(models, 0, {0, 9}), isEmpty);
    });
  });

  group('SiteUnloadEngine.indicesToEvictForLruCap', () {
    // A set literal keeps insertion order, so `loaded` lists the sites
    // LRU-first: oldest activation first, a re-activation moved to the end.
    _lruCases([
      (name: 'returns empty when within cap',
          loaded: {0, 1, 2}, target: 3, cap: 5, tiers: tiers(), evicts: isEmpty),
      // Loaded order: 0 (oldest), 1, 2. Activating index 3 would make 4
      // loaded; cap is 3, so the oldest (0) is evicted.
      (name: 'evicts oldest when adding target overflows cap',
          loaded: {0, 1, 2}, target: 3, cap: 3, tiers: tiers(), evicts: [0]),
      (name: 'evicts multiple when overflow > 1',
          loaded: {0, 1, 2, 3}, target: 4, cap: 2, tiers: tiers(),
          evicts: [0, 1, 2]),
      // Re-activating index 0 doesn't add a new slot — projected count is
      // still 3, so no eviction needed at cap=3.
      (name: 'skips the target index even at the front of loaded order',
          loaded: {0, 1, 2}, target: 0, cap: 3, tiers: tiers(),
          evicts: isEmpty),
      // Cap is 2, projected is 4 with new index 3 → overflow 2. With
      // index 0 protected, the engine should evict 1 and 2 instead.
      (name: 'skips protected indices (e.g. currently active site)',
          loaded: {0, 1, 2}, target: 3, cap: 2, tiers: tiers(active: {0}),
          evicts: [1, 2]),
      // Caller bumps re-activated sites to the end. After visiting 0, 1,
      // 2, then re-visiting 0, the order becomes 1, 2, 0 — so the next
      // overflow evicts 1, not 0.
      (name: 'respects access-order updates (LRU semantics)',
          loaded: {1, 2, 0}, target: 3, cap: 3, tiers: tiers(), evicts: [1]),
      // Activations in order: 0, 1, 2, 3 — then 1 bumped, then 0 bumped.
      // Final order: 2, 3, 1, 0. Cap=2 with new index 4 → overflow 3,
      // evict 2, 3, 1 (oldest three) and keep 0 + new 4.
      (name: 'eviction order respects multiple bumps',
          loaded: {2, 3, 1, 0}, target: 4, cap: 2, tiers: tiers(),
          evicts: [2, 3, 1]),
      (name: 'empty loadedIndices needs no eviction',
          loaded: <int>{}, target: 0, cap: 5, tiers: tiers(), evicts: isEmpty),
      (name: 'cap of 1 evicts every prior site',
          loaded: {0}, target: 1, cap: 1, tiers: tiers(), evicts: [0]),
      // Loaded = {0, 1, 2}, cap=3, target=2 (already loaded). Projected
      // count stays at 3, no eviction.
      (name: 'exactly-at-cap re-activation does not evict',
          loaded: {0, 1, 2}, target: 2, cap: 3, tiers: tiers(),
          evicts: isEmpty),
      // Pathological: every loaded site is protected and target adds
      // one more. There's nothing to evict. Engine returns [] rather
      // than evicting a protected site.
      (name: 'all loaded sites protected — overflow is unavoidable, returns []',
          loaded: {0, 1}, target: 2, cap: 1, tiers: tiers(active: {0, 1}),
          evicts: isEmpty),
      // Order: 0 (oldest), 1, 2. Cap=2 with target=3 → overflow 2,
      // evict 0 and 1 normally. Protect 0 → evict 1 and 2 instead.
      (name: 'protected indices kept even when oldest',
          loaded: {0, 1, 2}, target: 3, cap: 2, tiers: tiers(active: {0}),
          evicts: [1, 2]),
      // Loaded = {0, 1}, cap=2, target=0. Projected stays at 2 (target
      // is already loaded), so no eviction. protectedIndices is the
      // currently-active site, which may or may not equal target.
      (name: 're-activation at cap is a no-op (target already loaded)',
          loaded: {0, 1}, target: 0, cap: 2, tiers: tiers(active: {0}),
          evicts: isEmpty),
      // Loaded = {0, 1}, cap=1 (already over cap from a prior config
      // change or settings import). Re-activating the protected target
      // doesn't change the count, but the engine still pulls back to
      // cap by evicting the non-target non-protected entry.
      (name: 'over-cap state recovers via eviction even on target re-activation',
          loaded: {0, 1}, target: 0, cap: 1, tiers: tiers(active: {0}),
          evicts: [1]),
      // Degenerate but well-defined: cap=0 with target → projected 3,
      // overflow 3. All non-target loaded sites are evictable.
      (name: 'cap of 0 evicts every non-target non-protected entry',
          loaded: {0, 1}, target: 2, cap: 0, tiers: tiers(), evicts: [0, 1]),
    ]);

    group('preferKeepIndices (active-webspace soft-keep)', () {
      _lruCases([
        // Loaded LRU order: 0 (oldest), 1, 2, 3 (newest).
        // Active webspace = {0, 2}; sites 1 and 3 are outside.
        // Cap=4 with target=4 → overflow 1. Naive LRU would evict 0;
        // soft-keep prefers to evict 1 (the oldest out-of-set).
        (name: 'out-of-set candidates are evicted before in-set candidates',
            loaded: {0, 1, 2, 3}, target: 4, cap: 4,
            tiers: tiers(keep: {0, 2}), evicts: [1]),
        // Loaded: 0, 1, 2, 3. Active webspace = {0, 1, 2, 3} (everything).
        // Cap=2 with target=4 → overflow 3. Out-of-set is empty, so the
        // engine falls through to in-set in LRU order: evict 0, 1, 2.
        (name: 'falls back to in-set when out-of-set is exhausted',
            loaded: {0, 1, 2, 3}, target: 4, cap: 2,
            tiers: tiers(keep: {0, 1, 2, 3}), evicts: [0, 1, 2]),
        // Loaded: 0 (out), 1 (in), 2 (out), 3 (in), 4 (in), 5 (in).
        // Cap=3 with target=6 → overflow 4. Out-of-set = [0, 2] (2
        // candidates), in-set = [1, 3, 4, 5]. Need 4 → take 0, 2,
        // then 1, 3 from in-set.
        (name: 'mixes tiers when out-of-set is too small',
            loaded: {0, 1, 2, 3, 4, 5}, target: 6, cap: 3,
            tiers: tiers(keep: {1, 3, 4, 5}), evicts: [0, 2, 1, 3]),
        // Site 0 is hard-protected; site 1 is in soft-keep; sites 2, 3
        // are out-of-set. Cap=3 with target=4 → overflow 2.
        // Eviction: out-of-set first ([2, 3]) — exhausts overflow.
        // Site 0 (protected) and site 1 (soft-keep) both stay.
        (name: 'protectedIndices wins over preferKeepIndices',
            loaded: {0, 1, 2, 3}, target: 4, cap: 3,
            tiers: tiers(active: {0}, keep: {1}), evicts: [2, 3]),
        // Loaded: 0 (out), 1 (in), 2 (out, hard-protected), 3 (in,
        // hard-protected). Cap=2 with target=4 → overflow 2.
        // Non-protected eligible: 0 (out), 1 (in). Out tier supplies
        // [0]; need one more → in tier supplies [1].
        (name: 'a soft-keep site can still be evicted if hard-protected covers '
            'the keep room',
            loaded: {0, 1, 2, 3}, target: 4, cap: 2,
            tiers: tiers(active: {2, 3}, keep: {1, 3}), evicts: [0, 1]),
        // Sanity check: when no soft-keep is provided, eviction order
        // is pure LRU (oldest first) — backwards-compatible default.
        // Cap=3 with target=3 (new) → overflow 1 → evict [0].
        (name: 'empty preferKeepIndices == old single-tier behavior',
            loaded: {0, 1, 2}, target: 3, cap: 3, tiers: tiers(), evicts: [0]),
        // The active webspace can list site indices that aren't loaded
        // yet (haven't been visited). Those don't affect eviction
        // because the engine only iterates loadedIndices.
        // Cap=3 with target=3 (new) → overflow 1. Site 0 is in soft-keep;
        // sites 4/5/99 are noise. Out-of-set candidates: [1, 2]. Evict
        // oldest: [1].
        (name: 'preferKeepIndices may include unloaded sites without effect',
            loaded: {0, 1, 2}, target: 3, cap: 3,
            tiers: tiers(keep: {0, 4, 5, 99}), evicts: [1]),
        // Loaded in order: 0 (out), 1 (in), 2 (out), 3 (in). Then 0
        // gets bumped (re-activation) → order becomes 1, 2, 3, 0.
        // Cap=2 with target=4 → overflow 3. Out-of-set in LRU order:
        // [2, 0]. In-set in LRU order: [1, 3]. Need 3 → [2, 0, 1].
        (name: 'respects access-order within each tier with target',
            loaded: {1, 2, 3, 0}, target: 4, cap: 2,
            tiers: tiers(keep: {1, 3}), evicts: [2, 0, 1]),
      ]);
    });
  });

  group('SiteUnloadEngine eviction priority — full hierarchy', () {
    // Canonical scenario for documenting and locking down the priority
    // ordering. Five loaded sites in LRU order [0, 1, 2, 3, 4]:
    //
    //   index 0 → in soft-keep (active webspace), oldest
    //   index 1 → standard, no flags
    //   index 2 → hard-protected (currently-active site)
    //   index 3 → standard, no flags
    //   index 4 → in soft-keep, newest
    //
    // From most-likely-to-be-evicted to least:
    //   tier A: standard, oldest first   → 1, 3
    //   tier B: soft-keep, oldest first  → 0, 4
    //   never:  hard-protected, target   → 2 (and any targetIndex)
    final hierarchy = tiers(active: {2}, keep: {0, 2, 4});

    _lruCases([
      // Cap=1 with target=5 → projected 6, overflow 5. The engine
      // exhausts tier A (1, 3) then tier B (0, 4). Site 2 is
      // hard-protected so it's never evicted, even though we'd need
      // to drop more sites to actually fit the cap. Returns the four
      // safely-evictable indices in the documented order.
      (name: 'LruCap evicts strictly in tier order (1, 3, 0, 4)',
          loaded: {0, 1, 2, 3, 4}, target: 5, cap: 1, tiers: hierarchy,
          evicts: [1, 3, 0, 4]),
      // Cap=4 with target=5 → projected 6, overflow 1. Pick index 1
      // (oldest in tier A). Sites 3, 0, 4 stay; 2 is protected.
      (name: 'LruCap with overflow=1 takes the oldest tier-A site',
          loaded: {0, 1, 2, 3, 4}, target: 5, cap: 5, tiers: hierarchy,
          evicts: [1]),
      // Cap=2 with target=5 → projected 6, overflow 4 (need 4
      // candidates). Tier A supplies [1, 3]; tier B supplies [0, 4].
      // Result: [1, 3, 0, 4]. Same as the cap=1 case because tier A
      // had only 2 candidates and protection takes the rest.
      (name: 'LruCap with overflow=3 reaches into tier B',
          loaded: {0, 1, 2, 3, 4}, target: 5, cap: 2, tiers: hierarchy,
          evicts: [1, 3, 0, 4]),
      // Production scenario the user asked about: site 0 is the LRU
      // front (oldest, would be next out under the cap) AND the user
      // re-activates it. The engine excludes targetIndex from the
      // candidate iteration, so 0 is never picked even though it's
      // both the oldest AND in the soft-keep tier. Cap=3 with
      // target=0 (re-activation) → projected stays at 4, overflow 1
      // (we're already over cap). Eviction must spare target.
      // Previous active was 2 (different from target — common case
      // when the user is switching sites, not just re-tapping the
      // already-active one). Active webspace contains the target plus
      // one more.
      // outOfKeep = [3] (1 in keep, 2 protected, 0 is target).
      // inKeep = [1] (0 is target).
      // overflow=1, take outOfKeep first → [3]. Target survives.
      (name: 'user re-activates the site that would otherwise be next to evict',
          loaded: {0, 1, 2, 3}, target: 0, cap: 3,
          tiers: tiers(active: {2}, keep: {0, 1}), evicts: [3]),
      // In production, _setCurrentIndex passes _currentIndex as
      // protectedIndices and _getFilteredSiteIndices() as
      // preferKeepIndices. The active site is typically in the active
      // webspace, so the intersection is non-empty by design. The
      // overlap must NOT cause double-counting or skip the site
      // entirely from soft-keep semantics for *other* sites.
      // Loaded LRU: [0, 1, 2]. Active = 1 (in active webspace).
      // Active webspace = {0, 1}. Cap=2 with target=3 → overflow 2.
      // Tier A: [2]; tier B: [0]; protected: 1. Take [2, 0] → 0 is
      // demoted to last because it's in soft-keep.
      (name: 'protected ∩ softKeep is the production case (active site is both)',
          loaded: {0, 1, 2}, target: 3, cap: 2,
          tiers: tiers(active: {1}, keep: {0, 1}), evicts: [2, 0]),
    ]);
  });
}

/// One `indicesToEvictForLruCap` case per test; [loaded] is in LRU order.
void _lruCases(
    List<
            ({
              String name,
              Set<int> loaded,
              int target,
              int cap,
              SiteRetentionResolver tiers,
              Object evicts,
            })>
        cases) {
  for (final c in cases) {
    test(c.name, () {
      expect(
        SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: c.target,
          loadedIndices: c.loaded,
          maxLoadedSites: c.cap,
          priorityOf: c.tiers,
        ),
        c.evicts,
      );
    });
  }
}
