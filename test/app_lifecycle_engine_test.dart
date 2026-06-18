import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';

void main() {
  group('AppLifecycleEngine.activeLoadedIndex', () {
    test('null currentIndex yields null', () {
      expect(
        AppLifecycleEngine.activeLoadedIndex(
          currentIndex: null,
          siteCount: 3,
          loadedIndices: {0, 1, 2},
        ),
        isNull,
      );
    });

    test('out-of-bounds currentIndex yields null', () {
      expect(
        AppLifecycleEngine.activeLoadedIndex(
          currentIndex: 5,
          siteCount: 3,
          loadedIndices: {0, 1, 2, 5},
        ),
        isNull,
      );
      expect(
        AppLifecycleEngine.activeLoadedIndex(
          currentIndex: -1,
          siteCount: 3,
          loadedIndices: {0},
        ),
        isNull,
      );
    });

    test('active but not loaded yields null', () {
      expect(
        AppLifecycleEngine.activeLoadedIndex(
          currentIndex: 1,
          siteCount: 3,
          loadedIndices: {0, 2},
        ),
        isNull,
      );
    });

    test('active, in-bounds and loaded yields the index', () {
      expect(
        AppLifecycleEngine.activeLoadedIndex(
          currentIndex: 1,
          siteCount: 3,
          loadedIndices: {0, 1},
        ),
        1,
      );
    });
  });

  group('AppLifecycleEngine.backgroundPlan', () {
    test('no eligible active site: nothing to pause or capture', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: null,
        siteCount: 2,
        loadedIndices: {0, 1},
        notificationsEnabled: (_) => false,
      );
      expect(plan.jsPauseIndex, isNull);
      expect(plan.captureStateIndex, isNull);
    });

    test('active not loaded: nothing to pause or capture', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 2,
        siteCount: 3,
        loadedIndices: {0, 1},
        notificationsEnabled: (_) => false,
      );
      expect(plan.jsPauseIndex, isNull);
      expect(plan.captureStateIndex, isNull);
    });

    test('loaded non-notification active site: pause and capture it', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 1,
        siteCount: 3,
        loadedIndices: {0, 1},
        notificationsEnabled: (_) => false,
      );
      expect(plan.jsPauseIndex, 1);
      expect(plan.captureStateIndex, 1);
    });

    test('notification active site: capture but do NOT pause', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 1,
        siteCount: 3,
        loadedIndices: {0, 1},
        notificationsEnabled: (i) => i == 1,
      );
      expect(plan.jsPauseIndex, isNull);
      expect(plan.captureStateIndex, 1);
    });

    // Regression guard for issue #333 / AOH-006: a URL-ephemeral
    // (alwaysOpenHome / incognito) site that is active when the app is
    // backgrounded must be paused + captured like any other site, NOT reset
    // to its initUrl or disposed. The engine offers no reset output, so a
    // flagged site is indistinguishable from a plain one here.
    test('URL-ephemeral active site is paused+captured, never reset', () {
      const flaggedIndex = 1;
      // Model: site 1 is alwaysOpenHome/incognito (urlEphemeral) but NOT a
      // notification site. The plan must treat it like a normal site.
      bool urlEphemeral(int i) => i == flaggedIndex;
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: flaggedIndex,
        siteCount: 3,
        loadedIndices: {0, 1, 2},
        notificationsEnabled: (_) => false,
      );
      expect(plan.jsPauseIndex, flaggedIndex);
      expect(plan.captureStateIndex, flaggedIndex);
      // The engine exposes no field that could carry a reset for the flagged
      // site; the only signals are pause + capture, identical to a plain site.
      expect(urlEphemeral(flaggedIndex), isTrue,
          reason: 'sanity: the index under test is the flagged one');
    });
  });

  group('AppLifecycleEngine.resumeJsIndex', () {
    test('no eligible active site yields null', () {
      expect(
        AppLifecycleEngine.resumeJsIndex(
          currentIndex: null,
          siteCount: 2,
          loadedIndices: {0, 1},
          notificationsEnabled: (_) => false,
        ),
        isNull,
      );
    });

    test('loaded non-notification active site resumes', () {
      expect(
        AppLifecycleEngine.resumeJsIndex(
          currentIndex: 0,
          siteCount: 2,
          loadedIndices: {0, 1},
          notificationsEnabled: (_) => false,
        ),
        0,
      );
    });

    test('notification active site is not resumed (never paused)', () {
      expect(
        AppLifecycleEngine.resumeJsIndex(
          currentIndex: 0,
          siteCount: 2,
          loadedIndices: {0, 1},
          notificationsEnabled: (i) => i == 0,
        ),
        isNull,
      );
    });

    test('probe target (activeLoadedIndex) covers notification sites too', () {
      // resumeJsIndex skips notif sites, but the renderer probe should still
      // run against them: activeLoadedIndex returns the notif site.
      expect(
        AppLifecycleEngine.resumeJsIndex(
          currentIndex: 0,
          siteCount: 2,
          loadedIndices: {0},
          notificationsEnabled: (_) => true,
        ),
        isNull,
      );
      expect(
        AppLifecycleEngine.activeLoadedIndex(
          currentIndex: 0,
          siteCount: 2,
          loadedIndices: {0},
        ),
        0,
      );
    });
  });
}
