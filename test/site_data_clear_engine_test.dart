import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_data_clear_engine.dart';

/// Regression coverage for the chain of "Clear Site Data" bugs:
///
///  - 0.2.3: cookie-iterate + reload regardless of mode; container
///    mode left localStorage / IDB / SW / cache resident.
///  - #352: route container mode through `wipeContainers`. Relied on
///    the fork's `deleteContainer` actually completing, which on
///    iOS/macOS silently no-ops while a pending JS callback retains
///    the WKWebView past Flutter dispose (#360) — user observed an
///    intact LinkedIn session after the "Clear Site Data" tap.
///  - This iteration: bump `WebViewModel.containerRev` so the next
///    bind goes to a fresh `ws-<siteId>_r<rev>` container. The wipe is
///    no longer load-bearing; the previous-rev container is best-effort
///    GC'd, with startup GC as the safety net.
void main() {
  group('SiteDataClearEngine.planClear', () {
    test('container mode bumps the rev and lets GC clean up the orphan', () {
      final plan = SiteDataClearEngine.planClear(useContainers: true);

      expect(plan.bumpContainerRev, isTrue,
          reason: 'fresh `ws-<siteId>_r<rev>` is what makes the new '
              'webview land in an empty store, regardless of whether '
              'the old container can actually be deleted right now');
      expect(plan.disposeWebView, isTrue,
          reason: 'next IndexedStack rebuild must run getWebView so the '
              'new InAppWebView picks up the new containerRev');
      expect(plan.clearInModelCookies, isTrue,
          reason: 'in-model snapshot would otherwise carry stale entries '
              'into the persisted JSON until the new webview repopulates it');
      expect(plan.deleteKnownCookies, isFalse,
          reason: 'pointless when the new bind is already in a new '
              'container; legacy path uses this against the shared jar');
      expect(plan.userDrivenReload, isFalse,
          reason: 'dispose + rebuild constructs a fresh InAppWebView with '
              'a new UniqueKey, which loads the page from scratch');
      expect(plan.gcOrphans, isTrue,
          reason: 'kicks the previous-rev container delete now if the '
              'platform-view tear-down has finished; startup GC catches '
              'the rest. Best-effort, fire-and-forget at the call site');
    });

    test('legacy mode keeps cookie-iteration + reload', () {
      final plan = SiteDataClearEngine.planClear(useContainers: false);

      expect(plan.bumpContainerRev, isFalse,
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
      expect(plan.gcOrphans, isFalse,
          reason: 'nothing to GC in legacy mode');
    });

    test('the two plans are not equal — the engine MUST branch', () {
      final container = SiteDataClearEngine.planClear(useContainers: true);
      final legacy = SiteDataClearEngine.planClear(useContainers: false);
      expect(container, isNot(equals(legacy)),
          reason: 'a single un-branched plan is the original 0.2.3 bug');
    });
  });
}
