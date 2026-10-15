import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/mock_container_native.dart';
import 'helpers/mock_cookie_manager.dart';

/// The page as an activation sees it, recording what it tells the user.
class _Page implements ActivationHost, SurfaceHost {
  final toasts = <String Function(AppLocalizations)>[];
  var exitedFullscreen = false;

  @override
  bool mounted = true;

  @override
  void rebuild() {}

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) =>
      toasts.add(message);

  @override
  Future<void> commitSites(SiteSetChange change) async {}

  @override
  void forgetTabReturns() {}

  @override
  void enterFullscreen() {}

  @override
  void exitFullscreen() => exitedFullscreen = true;

  @override
  Future<void> refreshRoutes({int? activeIndex}) async {}

  @override
  void syncTorExitPin(Set<int> indices) {}

  @override
  Future<void> probeRenderer(WebViewModel model,
      {required String trigger}) async {}

  @override
  void backgroundSitesChanged() {}
}

/// The legacy engine's residency over [sites]: one shared jar.
class _SharedJar implements ResidencyHost {
  _SharedJar(this.sites, {required this.sharedJar});

  final SiteRuntime sites;

  @override
  final CookieIsolationEngine sharedJar;

  @override
  List<WebViewModel> get models => sites.models;

  @override
  Set<int> get loadedIndices => sites.loaded;

  @override
  Future<void> captureNavState(WebViewModel model) async {}

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) {}

  @override
  List<WebViewModel> identities({int? except}) => sites.models;

  @override
  SiteRetentionPriority priorityOf(int index) => SiteRetentionPriority.loaded;

  @override
  ProxyTopology get proxyTopology => ProxyTopology.of(
      linux: false,
      android: false,
      routerActive: false,
      sharesDefaultSession: (_) => false);

  @override
  bool get torAvailable => false;
}

/// A site opened while the shared jar does not answer is not shown: until
/// the jar is emptied and refilled it can hold another same-base-domain
/// site's session (ISO-001).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'ISO-014: an activation whose cookie restore fails shows the webspace '
      'list and says why, not the site', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final jar = MockCookieManager()..failing.add(JarCall.read);
    final site = WebViewModel(initUrl: 'https://github.com/', name: 'GitHub');
    final sites = SiteRuntime()..apply(SitesLoaded([site]));
    final page = _Page();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: _SharedJar(sites,
          sharedJar: CookieIsolationEngine(
              cookieManager: jar, storage: MockCookieSecureStorage())),
      navStates: InMemoryWebViewStateStorage(),
      containers:
          ContainerIsolationEngine(containerNative: MockContainerNative()),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );

    await activation.setCurrentIndex(0);

    expect(sites.current, isNull);
    expect(sites.loaded, isEmpty);
    expect(page.exitedFullscreen, isTrue);
    expect(page.toasts.map((m) => m(en)),
        ['Could not open GitHub: its cookies could not be restored']);
  });
}
