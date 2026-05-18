import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_data_clear_engine.dart';

/// Regression coverage for the chain of "Clear Site Data" bugs:
///
///  - 0.2.3: cookie-iterate + reload regardless of mode; container
///    mode left localStorage / IDB / SW / cache resident.
///  - #352: route container mode through the fork's `deleteContainer`.
///    Silently no-oped on iOS/macOS while a pending JS callback
///    retained the WKWebView past Flutter dispose (#360).
///  - privacy-v2 fork cut: introduced `clearContainerData` mapping to
///    `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)` — the
///    primitive Apple actually supports while a store is bound. This
///    plan now routes through that and disposes the cached widget so
///    the next rebuild paints a fresh page.
void main() {
  group('SiteDataClearEngine.planClear', () {
    test('container mode clears in place and forces widget recreation', () {
      final plan = SiteDataClearEngine.planClear(useContainers: true);

      expect(plan.clearContainer, isTrue,
          reason: 'fork\'s clearContainerData wipes cookies / DOM '
              'storage / IDB / SW / HTTP cache for the named container '
              'while the WKWebView stays bound');
      expect(plan.disposeWebView, isTrue,
          reason: 'next IndexedStack rebuild must construct a fresh '
              'InAppWebView so the user sees a clean page AND Android\'s '
              'per-WebView HTTP cache (not reached by clearContainerData) '
              'gets dropped along with the old widget');
      expect(plan.clearInModelCookies, isTrue,
          reason: 'in-model snapshot would otherwise carry stale entries '
              'into the persisted JSON until the new webview repopulates it');
      expect(plan.deleteKnownCookies, isFalse,
          reason: 'clearContainerData already drops every cookie in the '
              'container; legacy path uses this against the shared jar');
      expect(plan.userDrivenReload, isFalse,
          reason: 'dispose + rebuild constructs a fresh InAppWebView with '
              'a new UniqueKey, which loads the page from scratch');
    });

    test('legacy mode keeps cookie-iteration + reload', () {
      final plan = SiteDataClearEngine.planClear(useContainers: false);

      expect(plan.clearContainer, isFalse,
          reason: 'no per-site container exists in legacy mode');
      expect(plan.disposeWebView, isFalse,
          reason: 'controller is still alive; reload() picks up the delete');
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
