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
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
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
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
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
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
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
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
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
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
      );
      expect(plan.jsPauseIndex, flaggedIndex);
      expect(plan.captureStateIndex, flaggedIndex);
      // The engine exposes no field that could carry a reset for the flagged
      // site; the only signals are pause + capture, identical to a plain site.
      expect(urlEphemeral(flaggedIndex), isTrue,
          reason: 'sanity: the index under test is the flagged one');
    });
  });

  // Chromium commits cookies to disk lazily, so a session cookie written
  // moments before the OS kills a backgrounded app is never persisted and the
  // user comes back logged out (issues #524, #525). Backgrounding is the last
  // point we control, so the plan asks for a flush there.
  group('AppLifecycleEngine.backgroundPlan cookie flush', () {
    test('loaded site on a flush-capable platform: flush', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 1,
        siteCount: 3,
        loadedIndices: {0, 1},
        notificationsEnabled: (_) => false,
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
      );
      expect(plan.flushCookies, isTrue);
    });

    // `CookieManager.flush` is implemented on Android only; the platform
    // interface's default throws UnimplementedError, so asking for a flush
    // anywhere else turns a durability hook into a crash on every background.
    test('platform without flush support: never flush', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 1,
        siteCount: 3,
        loadedIndices: {0, 1},
        notificationsEnabled: (_) => false,
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: false,
      );
      expect(plan.flushCookies, isFalse);
    });

    test('nothing loaded: no flush', () {
      // No webview loaded this session means no page could have written a
      // cookie, so there is nothing pending to commit.
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: null,
        siteCount: 3,
        loadedIndices: const {},
        notificationsEnabled: (_) => false,
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
      );
      expect(plan.flushCookies, isFalse);
    });

    // Notification sites are exempt from the per-instance JS pause, and the
    // flush must not inherit that exemption: they are the sites most likely to
    // be alive and writing cookies when the app is backgrounded.
    test('notification active site: no JS pause, but still flush', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 1,
        siteCount: 3,
        loadedIndices: {0, 1},
        notificationsEnabled: (i) => i == 1,
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
      );
      expect(plan.jsPauseIndex, isNull);
      expect(plan.flushCookies, isTrue);
    });

    // A site can be loaded without being the active one (background tab, or
    // the user backgrounded the app from the home screen). Its cookie writes
    // are just as unflushed.
    test('loaded but no active site: still flush', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: null,
        siteCount: 3,
        loadedIndices: {0, 2},
        notificationsEnabled: (_) => false,
        backgroundAudioEnabled: (_) => false,
        cookieFlushSupported: true,
      );
      expect(plan.jsPauseIndex, isNull);
      expect(plan.captureStateIndex, isNull);
      expect(plan.flushCookies, isTrue);
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
          backgroundAudioEnabled: (_) => false,
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
          backgroundAudioEnabled: (_) => false,
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
          backgroundAudioEnabled: (_) => false,
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
          backgroundAudioEnabled: (_) => false,
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

  group('BGAUDIO-002 background-audio pause exemption', () {
    test('active background-audio site: capture but do NOT pause', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 1,
        siteCount: 3,
        loadedIndices: {0, 1},
        notificationsEnabled: (_) => false,
        backgroundAudioEnabled: (i) => i == 1,
        cookieFlushSupported: true,
      );
      expect(plan.jsPauseIndex, isNull);
      expect(plan.captureStateIndex, 1);
    });

    test('LOADED background-audio site vetoes the pause of a plain active site',
        () {
      // The app-lifecycle JS pause is process-global on Android: pausing the
      // active site would also freeze the backgrounded audio site's player.
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 0,
        siteCount: 3,
        loadedIndices: {0, 2},
        notificationsEnabled: (_) => false,
        backgroundAudioEnabled: (i) => i == 2,
        cookieFlushSupported: true,
      );
      expect(plan.jsPauseIndex, isNull);
      expect(plan.captureStateIndex, 0);
    });

    test('unloaded background-audio site does not veto the pause', () {
      final plan = AppLifecycleEngine.backgroundPlan(
        currentIndex: 0,
        siteCount: 3,
        loadedIndices: {0},
        notificationsEnabled: (_) => false,
        backgroundAudioEnabled: (i) => i == 2,
        cookieFlushSupported: true,
      );
      expect(plan.jsPauseIndex, 0);
      expect(plan.captureStateIndex, 0);
    });

    test('resume mirrors the skipped pause (nothing to resume)', () {
      expect(
        AppLifecycleEngine.resumeJsIndex(
          currentIndex: 0,
          siteCount: 3,
          loadedIndices: {0, 2},
          notificationsEnabled: (_) => false,
          backgroundAudioEnabled: (i) => i == 2,
        ),
        isNull,
      );
    });

    test('out-of-bounds loaded index never reaches the flag callback', () {
      expect(
        AppLifecycleEngine.anyLoadedBackgroundAudio(
          siteCount: 2,
          loadedIndices: {0, 5},
          backgroundAudioEnabled: (i) {
            expect(i, lessThan(2));
            return false;
          },
        ),
        isFalse,
      );
    });
  });
}
