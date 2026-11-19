import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_reset_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

class _Page extends Fake implements TabsHost, SiteResetHost {
  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  Future<void> commitSites(SiteSetChange change) async {}

  @override
  void cancelPendingCapture(SiteId siteId) {}

  @override
  NavCapture? beginNavCapture(WebViewModel site) => null;

  @override
  void noteUnloaded(WebViewModel model, {required String why}) {}
}

class _Residency extends Fake implements ResidencyHost {
  @override
  final ProxyTopology proxyTopology = ProxyTopology.of(
    binding: ProxyBinding.perSite,
    sharesDefaultSession: (_) => false,
  );
}

/// A home shortcut opens its site at home with nothing of the page it was
/// left on, whether or not Always open Home is on (HS-006, #1046).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const home = 'https://maps.example/';
  const deep = 'https://maps.example/@40.7,-74.0,15z';

  Future<({WebViewModel site, InMemoryWebViewStateStorage files})> launch(
      {required bool tabsEnabled}) async {
    final site = WebViewModel(initUrl: home, tabsEnabled: tabsEnabled)
      ..currentUrl = deep;
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([site]));
    final files = InMemoryWebViewStateStorage();
    await files.saveState(site.activeStateKey,
        state: Uint8List.fromList(const [7, 7, 7]));
    final page = FakeActivationPage();
    final host = _Page();
    final resets = SiteResetController(
      sites,
      host: host,
      tabs: TabsController(sites,
          host: host, navStates: files, residency: _Residency()),
      activation: SiteActivationController(
        sites,
        host: page,
        residency: FakeResidency(sites),
        navStates: files,
        surface:
            SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
      ),
    );
    await resets.resetHomeOnLaunch(site);
    return (site: site, files: files);
  }

  test('a site without tabs or Always open Home is sent home in place, its '
      'saved back stack forgotten (HS-006)', () async {
    final (:site, :files) = await launch(tabsEnabled: false);

    expect(site.currentUrl, home);
    expect(await files.loadState(site.activeStateKey), isNull);
  });

  test('a site with tabs and no Always open Home lands on a tab at home, the '
      'tab it was on kept (HS-006, TAB-014)', () async {
    final (:site, :files) = await launch(tabsEnabled: true);

    expect(site.currentUrl, home);
    expect(await files.loadState(site.activeStateKey), isNull);
    expect(site.tabs.map((t) => t.url), contains(deep));
  });
}
