import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/mock_cookie_manager.dart';
import 'helpers/model_fixture.dart';

/// The page as an activation sees it, recording what it tells the user.
final class _Page implements ActivationHost, SurfaceHost {
  final toasts = <String Function(AppLocalizations)>[];
  var exitedFullscreen = false;

  @override
  bool get mounted => true;

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
  Future<void> refreshRoutes({WebViewModel? active}) async {}

  @override
  Future<bool> isOnline() async => true;

  @override
  Future<void> spawned(Future<void> Function() flow) => flow();

  @override
  void syncTorExitPin(Iterable<WebViewModel> sites) {}

  @override
  Future<void> probeRenderer(WebViewModel model,
      {required String trigger}) async {}

  @override
  void backgroundSitesChanged() {}
}

/// The residency of [sites] on the jar they hold.
final class _Residency implements ResidencyHost {
  _Residency(this.sites);

  final SiteRuntime sites;

  @override
  ResidencyCaps get caps => kResidencyCaps;

  @override
  List<WebViewModel> get models => sites.models;

  @override
  RuntimeVars<WebViewModel> get vars => sites.vars;

  @override
  Isolation get isolation => sites.isolation;

  @override
  NavCapture? beginNavCapture(WebViewModel model) => null;

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) {}

  @override
  List<WebViewModel> identities({int? except}) =>
      sites.slotIdentities(except: except);

  @override
  SiteRetentionPriority priorityOf(int index) =>
      sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => ProxyTopology.of(
      binding: ProxyBinding.perSite,
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'ISO-014: an activation whose cookie restore fails shows the webspace '
      'list and says why, not the site', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final jar = MockCookieManager();
    final shown = WebViewModel(initUrl: 'https://example.com/', name: 'Example');
    final target = WebViewModel(initUrl: 'https://github.com/', name: 'GitHub');
    final sites = SiteRuntime()
      ..isolation = fakeSharedJar(cookies: jar)
      ..applied(SitesLoaded([shown, target]));
    final page = _Page();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: _Residency(sites),
      navStates: InMemoryWebViewStateStorage(),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );
    await activation.activate(shown);
    expect(sites.shown, shown);

    jar.failing.add(JarCall.read);
    await activation.activate(target);

    expect(sites.shown, isNull,
        reason: 'the list, not the site on screen before the tap');
    expect(sites.loaded, isNot(contains(target)));
    expect(page.exitedFullscreen, isTrue);
    expect(page.toasts.map((m) => m(en)),
        ['Could not open GitHub: its cookies could not be restored']);
  });
}
