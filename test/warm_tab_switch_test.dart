import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/activation_step.dart' show FlowKind;
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_webview_controller.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

class _Page extends Fake implements TabsHost {
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

  @override
  ResidencyCaps get caps => kResidencyCaps;

  @override
  WarmLimits get warmLimits => kWarmLimits;

  @override
  bool flowInFlight(FlowKind kind) => false;
}

class _NavStates extends Fake implements WebViewStateStorage {
  @override
  Future<Uint8List?> loadState(String key) async => null;

  @override
  Future<bool> saveState(String key, {required Uint8List state}) async =>
      true;

  @override
  Future<void> removeState(String key) async {}

  @override
  Future<Uint8List?> takeState(String key) async => null;
}

const _frame = Commit.environment(Environment.frame);

/// The frame after a switch built a webview for the active tab: a fresh
/// stand-in for it, bound to that tab.
FakeWebViewController _built(WebViewModel site) {
  final view = FakeWebViewController();
  site.controller = view;
  site.tabBinding.bind(site.activeTabId, commit: _frame);
  return view;
}

/// The bug this pins: `_rebind` dropped every warm view the switch would
/// not keep warm, and the target, being shown, is never among them, so a
/// switch back to a warm tab dropped its view one line before showing it and
/// rebuilt the page. The model missed it: a rebuilt view and a warm one show
/// the same history label (`Inv_WarmShown`), so the replay matched either.
/// The assert in `_rebind` now refuses a warm target that is not shown.
void main() {
  test('TAB-023: a switch back to the tab left shows its warm view, no '
      'new one built', () async {
    final site = WebViewModel(initUrl: 'https://example.com/');
    final a = site.activeTabId;
    final b = SiteTab(url: 'https://example.com/b');
    site.setTabs([...site.tabs, b]);
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([site]));
    sites.seed(loaded: [site], shown: site);
    final tabs = TabsController(sites,
        host: _Page(), navStates: _NavStates(), residency: _Residency());

    final viewOfA = _built(site);
    await tabs.openTab(site, tabId: b.id);
    await tabs.settled();
    expect(site.warmViews.keys, [a], reason: 'A is kept warm as B shows');
    final viewOfB = _built(site);

    await tabs.openTab(site, tabId: a);
    await tabs.settled();
    expect(site.controller, same(viewOfA),
        reason: 'A is shown as it was, not built again');
    expect(site.warmViews.keys, [b.id]);
    expect(site.warmViews[b.id]!.controller, same(viewOfB));
  });
}
