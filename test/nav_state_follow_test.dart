import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/fake_webview_controller.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

/// [sites] behind a fake page, their back stacks in [navStates].
SiteActivationController _activation(
  SiteRuntime sites, {
  required WebViewStateStorage navStates,
}) {
  final page = FakeActivationPage();
  return SiteActivationController(
    sites,
    host: page,
    residency: FakeResidency(sites),
    navStates: navStates,
    surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
  );
}

/// [site] with a webview built for its active tab.
FakeWebViewController _built(WebViewModel site) {
  final view = FakeWebViewController();
  site.controller = view;
  site.tabBinding.frame(site.activeTabId,
      commit: const Commit.environment(Environment.frame));
  return view;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('PAUSE-009: going home saves the back stack of the site it left and '
      'keeps it loaded', () async {
    final site = WebViewModel(initUrl: 'https://news.example/');
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([site]));
    final navStates = InMemoryWebViewStateStorage();
    final activation = _activation(sites, navStates: navStates);

    await activation.activate(site);
    final view = _built(site);
    await activation.activate(null);
    await pumpEventQueue();

    expect(view.calls, contains('saveState'));
    expect(await navStates.loadState(site.activeStateKey), view.history);
    expect(sites.loaded, contains(site), reason: 'no dispose');
    expect(site.lifecycleState, SiteLifecycleState.resident);
  });

  test('PAUSE-009: a burst of navigations is saved once, after it settles',
      () {
    fakeAsync((async) {
      final site = WebViewModel(initUrl: 'https://news.example/');
      final sites = SiteRuntime()
        ..isolation = fakeContainers()
        ..applied(SitesLoaded([site]));
      final navStates = InMemoryWebViewStateStorage();
      final activation = _activation(sites, navStates: navStates);
      final view = _built(site);
      activation.followNavigation(site);

      for (var i = 0; i < 3; i++) {
        site.onNavigationCommitted!();
        async.elapse(const Duration(seconds: 1));
      }
      expect(view.calls, isNot(contains('saveState')),
          reason: 'each navigation restarts the window');
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(view.calls.where((c) => c == 'saveState'), hasLength(1));
    });
  });

  /// Held twice: the removal lets go of the site's webview
  /// ([SiteRuntime.apply]), and the capture re-checks that the site is still
  /// listed before it reads.
  test('a navigation capture of a site deleted inside the window '
      'does nothing', () {
    fakeAsync((async) {
      final site = WebViewModel(initUrl: 'https://news.example/');
      final other = WebViewModel(initUrl: 'https://mail.example/');
      final sites = SiteRuntime()
        ..isolation = fakeContainers()
        ..applied(SitesLoaded([site, other]));
      final activation = _activation(sites,
          navStates: InMemoryWebViewStateStorage());
      final view = _built(site);
      activation.followNavigation(site);

      site.onNavigationCommitted!();
      sites.applied(SiteRemoved(site));
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(view.calls, isNot(contains('saveState')));
    });
  });

  test('PAUSE-011: a navigation capture follows its site through a reorder '
      'inside the window', () {
    fakeAsync((async) {
      final site = WebViewModel(initUrl: 'https://news.example/');
      final other = WebViewModel(initUrl: 'https://mail.example/');
      final sites = SiteRuntime()
        ..isolation = fakeContainers()
        ..applied(SitesLoaded([site, other]));
      final navStates = InMemoryWebViewStateStorage();
      final activation = _activation(sites, navStates: navStates);
      final view = _built(site);
      final otherView = _built(other);
      activation.followNavigation(site);

      site.onNavigationCommitted!();
      sites.applied(const SitesMoved(0, to: 1));
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(view.calls, contains('saveState'));
      expect(otherView.calls, isNot(contains('saveState')),
          reason: 'by identity, not by the row the site held');
    });
  });

  test('a forgotten navigation capture never runs', () {
    fakeAsync((async) {
      final site = WebViewModel(initUrl: 'https://news.example/');
      final sites = SiteRuntime()
        ..isolation = fakeContainers()
        ..applied(SitesLoaded([site]));
      final activation = _activation(sites,
          navStates: InMemoryWebViewStateStorage());
      final view = _built(site);
      activation.followNavigation(site);

      site.onNavigationCommitted!();
      activation.forgetNavigation(site.siteId);
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(view.calls, isNot(contains('saveState')));
    });
  });
}
