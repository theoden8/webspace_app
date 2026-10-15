// PagePhases, one webview's life as its callbacks report it: which callbacks
// may act, and what a load needs in place before it starts.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/page_phase.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/web_intercept_native.dart';

import 'helpers/fake_platform_controller.dart';
import 'helpers/user_script_bridge_fakes.dart';

SiteBlocking _blocking({bool contentBlock = false}) => (
  clearUrls: false,
  dns: false,
  dnsLevel: null,
  contentBlock: contentBlock,
  localCdn: false,
  httpsUpgrade: false,
  contributesStats: false,
  blockedCookies: const {},
);

PagePhases _phases({bool contentBlock = false}) => PagePhases(
  blocking: _blocking(contentBlock: contentBlock),
  dnsLevel: () => kDnsLevelOff,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = FakePlatformController();
  final second = FakePlatformController();

  test('a live view moves through its loads', () {
    final p = _phases();
    expect(p.on(PageEvent.viewCreated, view: first), isTrue);
    expect(p.on(PageEvent.loadStarted, view: first), isTrue);
    expect(p.phase, PagePhase.loading);
    expect(p.on(PageEvent.commitVisible, view: first), isTrue);
    expect(p.on(PageEvent.loadStopped, view: first), isTrue);
    expect(p.phase, PagePhase.loaded);
    expect(p.on(PageEvent.loadStarted, view: first), isTrue,
        reason: 'the next navigation starts a load again');
  });

  test('a dead renderer\'s callbacks are dropped, and a remount starts over',
      () {
    final p = _phases();
    p.on(PageEvent.viewCreated, view: first);
    expect(p.on(PageEvent.rendererGone, view: first), isTrue);
    expect(p.on(PageEvent.rendererGone, view: first), isFalse,
        reason: 'a second report must not rebuild the site twice');
    expect(p.on(PageEvent.loadStopped, view: first), isFalse);
    expect(p.live(view: first), isFalse);

    p.unmounted();
    expect(p.on(PageEvent.viewCreated, view: second), isTrue);
    expect(p.live(view: second), isTrue);
    expect(p.on(PageEvent.loadStarted, view: first), isFalse,
        reason: 'the old view reports on a page nothing shows');
    expect(p.on(PageEvent.loadStarted, view: second), isTrue);
  });

  test('a disposed view\'s callbacks are dropped', () {
    final p = _phases();
    p.on(PageEvent.viewCreated, view: first);
    p.unmounted();
    expect(p.on(PageEvent.loadStopped, view: first), isFalse);
    expect(p.live(view: first), isFalse);
  });

  group('a load starts only with what the page needs (CB-001)', () {
    setUp(() => ContentBlockerService.instance.reset());

    test('before the content blocker is loaded, it is an assert', () {
      final p = _phases(contentBlock: true);
      p.on(PageEvent.viewCreated, view: first);
      expect(
        () => p.on(PageEvent.loadStarted, view: first),
        throwsA(isA<AssertionError>().having(
            (e) => '${e.message}', 'message', contains('contentBlocker'))),
      );
    });

    test('once it is loaded, the load starts', () async {
      SharedPreferences.setMockInitialValues({});
      await ContentBlockerService.instance.initialize(native: WebInterceptNative.initialize());
      final p = _phases(contentBlock: true);
      p.on(PageEvent.viewCreated, view: first);
      expect(p.on(PageEvent.loadStarted, view: first), isTrue);
    });

    test('a site that does not block asks nothing of it', () {
      final p = _phases();
      p.on(PageEvent.viewCreated, view: first);
      expect(p.on(PageEvent.loadStarted, view: first), isTrue);
    });
  });

  group('a script lands in the document it was decided for (US-007)', () {
    late PagePhases p;
    late FakeUserScriptController ctrl;
    setUp(() {
      p = _phases();
      ctrl = FakeUserScriptController();
      p.on(PageEvent.viewCreated, view: ctrl.platform);
      p.on(PageEvent.loadStarted, view: ctrl.platform);
    });

    test('while the document stays, it runs', () async {
      final page = p.page(ctrl);
      p.on(PageEvent.commitVisible, view: ctrl.platform);
      p.on(PageEvent.loadStopped, view: ctrl.platform);
      await page.evaluate('ONE();');
      expect(ctrl.evaluatedAny('ONE();'), isTrue);
    });

    test('the next load ends the document, asked for or not', () async {
      final page = p.page(ctrl);
      p.on(PageEvent.loadStarted, view: ctrl.platform);
      await page.evaluate('ONE();');
      expect(ctrl.evaluated, isEmpty);
    });

    test('a navigation only asked for leaves it: it may be cancelled',
        () async {
      final page = p.page(ctrl);
      p.asks();
      await page.evaluate('ONE();');
      expect(ctrl.evaluatedAny('ONE();'), isTrue);
      expect(p.asked, 1);
    });

    test('a dead renderer takes its documents with it', () async {
      final page = p.page(ctrl);
      p.on(PageEvent.rendererGone, view: ctrl.platform);
      await page.evaluate('ONE();');
      expect(ctrl.evaluated, isEmpty);
    });

    test('a remounted view starts its own documents', () async {
      final page = p.page(ctrl);
      p.unmounted();
      final next = FakeUserScriptController();
      p.on(PageEvent.viewCreated, view: next.platform);
      await page.evaluate('ONE();');
      expect(ctrl.evaluated, isEmpty);
    });
  });
}
