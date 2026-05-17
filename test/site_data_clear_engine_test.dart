import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_data_clear_engine.dart';

/// Regression coverage for the 0.2.3 "Clear Site Data" bug: the executor
/// in `_WebSpacePageState` used to call `deleteCookies` + `reload()`
/// regardless of isolation engine. In container mode that left
/// localStorage / IndexedDB / ServiceWorker / HTTP cache intact in the
/// per-site container and only dropped the cookies the in-model
/// snapshot already knew about. The plan asserted below pins the
/// dispose + wipe + recreate dance that the container path now takes.
///
/// If this test ever flips back to the legacy plan under
/// `useContainers: true`, the per-site "Clear Site Data" button is
/// silently broken for every user on a container-capable platform
/// (Android System WebView 110+ / iOS 17+ / macOS 14+ / Linux WPE 2.40+).
void main() {
  group('SiteDataClearEngine.planClear', () {
    test('container mode wipes the container and forces recreation', () {
      final plan = SiteDataClearEngine.planClear(useContainers: true);

      expect(plan.disposeWebView, isTrue,
          reason: 'container is in-use until the webview is gone; '
              'deleteContainer no-ops on an in-use container');
      expect(plan.dropFromLoadedIndices, isTrue,
          reason: 'IndexedStack must rebuild against the fresh container');
      expect(plan.wipeContainer, isTrue,
          reason: 'only wipeContainers drops localStorage / IDB / SW / cache');
      expect(plan.clearInModelCookies, isTrue,
          reason: 'in-model snapshot must not resurrect cookies on next save');
      expect(plan.deleteKnownCookies, isFalse,
          reason: 'pre-wipe deleteCookie pass is redundant and races the '
              'wipe; the bug it replaced left non-snapshot cookies behind');
      expect(plan.userDrivenReload, isFalse,
          reason: 'reload on the SAME disposed controller is a no-op; '
              'lazy recreation from setState is what loads the page');
    });

    test('legacy mode keeps cookie-iteration + reload', () {
      final plan = SiteDataClearEngine.planClear(useContainers: false);

      expect(plan.disposeWebView, isFalse);
      expect(plan.dropFromLoadedIndices, isFalse);
      expect(plan.wipeContainer, isFalse,
          reason: 'no per-site container exists in legacy mode');
      expect(plan.clearInModelCookies, isFalse,
          reason: 'capture-nuke-restore in CookieIsolationEngine reads '
              'this snapshot; nulling it here would corrupt that flow');
      expect(plan.deleteKnownCookies, isTrue,
          reason: 'only scoped action available against the shared jar');
      expect(plan.userDrivenReload, isTrue,
          reason: 'controller is still alive; reload picks up the delete');
    });

    test('the two plans are not equal — the engine MUST branch', () {
      final container = SiteDataClearEngine.planClear(useContainers: true);
      final legacy = SiteDataClearEngine.planClear(useContainers: false);
      expect(container, isNot(equals(legacy)),
          reason: 'a single un-branched plan is the original 0.2.3 bug');
    });
  });
}
