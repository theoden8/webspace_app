import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_coverage_engine.dart';
import 'package:webspace/services/proxy_refused.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/fake_auth_caches.dart';
import 'helpers/fake_proxy_relay.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

/// When router mode starts and what a proxied site does without it, under
/// each Android binding (PROXY-013, PROXY-008).
///
/// With per-site profiles the binding routes for the whole run: the router
/// starts at the launch where a site is proxied, or with the first proxy of a
/// run that had none, and a start that fails is not tried again; a proxied
/// site then shows the block instead of loading, and a site with no proxy
/// goes direct. Without them the binding keeps one rule for a site's own
/// proxy and the router never starts.
///
/// Drives the real `SiteNetworkController` and `ProxyRouterService` through
/// the relay fake and the probe fake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRelay relay;
  final router = ProxyRouterService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The rule writer asks first whether the platform takes a proxy at all;
    // uninitialised it answers no and every write is a no-op.
    await PlatformInfo.initialize();
    GlobalOutboundProxy.setInMemory(UserProxySettings(type: ProxyType.DEFAULT));
    relay = FakeRelay();
    router.resetForTest();
    router.setRelayForTest(relay);
    SiteNetworkController.attributionProbe = FakeAuthCaches(
      record: ({required nonce, required identity}) =>
          relay.probes[nonce] = identity,
    ).probe;
  });

  tearDown(() {
    router.resetForTest();
    ProxyManager.pinBindingForTest(null);
  });

  UserProxySettings http(String address) =>
      UserProxySettings(type: ProxyType.HTTP, address: address);

  ({SiteRuntime sites, SiteNetworkController network}) page(
    List<WebViewModel> models,
  ) {
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded(models));
    final host = FakeActivationPage();
    final residency = FakeResidency(sites);
    final network = SiteNetworkController(
      sites,
      host: host,
      residency: residency,
      activation: SiteActivationController(
        sites,
        host: host,
        residency: residency,
        navStates: InMemoryWebViewStateStorage(),
        surface: SurfaceRepaintController(host, repaints: false, traceSuffix: ''),
      ),
    );
    return (sites: sites, network: network);
  }

  final launch = (
    site: Future<WebViewModel?>.value(),
    settled: Future<void>.value(),
  );

  StoreBinding bindingOf(WebViewModel model) => WebViewFactory.storeBinding(
        model.sitePosture(
          globalUserScripts: const <UserScriptConfig>[],
          isolation: fakeContainers(),
        ),
      );

  group('with per-site profiles the relay carries every proxy (PROXY-013)',
      () {
    setUp(() => ProxyManager.pinBindingForTest(ProxyBinding.routed));

    test('the launch starts the router where a site is proxied', () async {
      final (:sites, :network) = page([
        WebViewModel(initUrl: 'https://one.test', proxySettings: http('10.0.0.1:8080')),
        WebViewModel(initUrl: 'https://two.test', proxySettings: http('10.0.0.2:8080')),
      ]);
      await network.activateRouter(launch: launch);

      expect(router.isActive, isTrue);
      expect(relay.installed, hasLength(2),
          reason: 'one route per site, each to its own upstream');
      expect(network.topology, isA<RoutedProxy>());
      for (final m in sites.models) {
        expect(network.topology.contends(m), isFalse,
            reason: 'nothing unloads another site for its proxy');
      }
    });

    test('a route refresh before the launch has decided leaves the start to '
        'it (PROXY-015)', () async {
      // The restore's own commit refreshes the routes before the launch
      // starts the router, which checks the launched site first and holds
      // the rest until its page settles.
      final (sites: _, :network) = page([
        WebViewModel(initUrl: 'https://one.test', proxySettings: http('10.0.0.1:8080')),
      ]);
      await network.refreshRoutes();
      expect(relay.startCalls, 0);
      await network.activateRouter(launch: launch);
      expect(relay.startCalls, 1);
      expect(router.isActive, isTrue);
    });

    test('a run with no proxy starts nothing, and its first proxy starts the '
        'router', () async {
      final one = WebViewModel(initUrl: 'https://one.test');
      final (sites: _, :network) =
          page([one, WebViewModel(initUrl: 'https://two.test')]);
      await network.activateRouter(launch: launch);
      expect(relay.startCalls, 0, reason: 'no relay without a proxy');
      expect(router.relayDown, isTrue);
      expect(bindingOf(one).relayDown, isFalse,
          reason: 'a site with no proxy goes direct');

      one.proxySettings = http('10.0.0.1:8080');
      expect(bindingOf(one).relayDown, isTrue,
          reason: 'built now, before any route refresh, it would not load');
      final refreshed = network.refreshRoutes(active: one);
      expect(router.isStarting, isTrue,
          reason: 'the start is visible before its first await, so a build '
              'that follows waits for it');
      expect(bindingOf(one).relayDown, isFalse);
      await refreshed;

      expect(relay.startCalls, 1);
      expect(router.isActive, isTrue);
      expect(relay.installed, hasLength(2));
      expect(
        WebViewFactory.refusesLoad(bindingOf(one), url: 'https://one.test/'),
        isNull,
      );
    });

    test('a start that fails leaves every proxied site blocked and every '
        'other one direct, for the run', () async {
      relay.canBind = false;
      final proxied = WebViewModel(
          initUrl: 'https://one.test', proxySettings: http('10.0.0.1:8080'));
      final direct = WebViewModel(initUrl: 'https://two.test');
      final (sites: _, :network) = page([proxied, direct]);
      proxied.webview = const SizedBox();
      direct.webview = const SizedBox();

      await network.activateRouter(launch: launch);

      expect(router.failed, isTrue);
      expect(proxied.webview, isNull,
          reason: 'built again, it shows the block rather than going on '
              'direct');
      expect(direct.webview, isNotNull, reason: 'nothing to rebuild');
      expect(
        WebViewFactory.refusesLoad(bindingOf(proxied),
            url: 'https://one.test/'),
        const Unprovable(),
      );
      expect(
        WebViewFactory.refusesLoad(bindingOf(direct),
            url: 'https://two.test/'),
        isNull,
      );

      relay.canBind = true;
      await network.refreshRoutes(active: proxied);
      expect(relay.startCalls, 1, reason: 'not tried again this run');
      expect(router.isActive, isFalse);
    });

    test('a proxied site waits for the relay, and is refused once it fails',
        () async {
      // `_applyRule` under the routed binding: what the site's webview runs
      // before its deferred first load.
      final site = WebViewModel(
          initUrl: 'https://one.test', proxySettings: http('10.0.0.1:8080'));
      final (sites: _, :network) = page([site]);
      await network.activateRouter(launch: launch);
      await expectLater(
        ProxyManager().setProxySettings(site.proxySettings,
            siteId: site.siteId, occupant: site.routeClaim.occupant),
        completes,
      );

      router.resetForTest();
      relay.canBind = false;
      await network.activateRouter(launch: launch);
      await expectLater(
        ProxyManager().setProxySettings(site.proxySettings,
            siteId: site.siteId, occupant: site.routeClaim.occupant),
        throwsA(isA<ProxyRefused>()),
      );
    });
  });

  group('without per-site profiles one rule carries a site\'s own proxy '
      '(PROXY-008)', () {
    setUp(() => ProxyManager.pinBindingForTest(ProxyBinding.processWide));

    test('the router never starts, at the launch or after', () async {
      final one = WebViewModel(
          initUrl: 'https://one.test', proxySettings: http('10.0.0.1:8080'));
      final (:sites, :network) = page([
        one,
        WebViewModel(initUrl: 'https://two.test', proxySettings: http('10.0.0.2:8080')),
      ]);
      await network.activateRouter(launch: launch);
      await network.refreshRoutes(active: one);

      expect(relay.startCalls, 0);
      expect(router.isActive, isFalse);
      expect(network.topology, isA<ProcessGlobalProxy>());
      for (final m in sites.models) {
        expect(network.topology.contends(m), isTrue,
            reason: 'a site with another proxy unloads the rest');
      }
      expect(bindingOf(one).relayDown, isFalse,
          reason: 'the site\'s own rule carries it, not the relay');
      expect(
        WebViewFactory.refusesLoad(bindingOf(one), url: 'https://one.test/'),
        isNull,
      );
    });
  });
}
