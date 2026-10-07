import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/background_wake_engine.dart';

/// A page that loads for [loadTicks] polls after a reload, then shows
/// [titleAfter], and posts its own notification on load when [postsOnLoad].
class _Page {
  _Page({
    required this.titleBefore,
    required this.titleAfter,
    this.loadTicks = 3,
    this.postsOnLoad = false,
  });

  final String? titleBefore;
  final String? titleAfter;
  final int loadTicks;
  final bool postsOnLoad;
  int? _ticksLeft;
  DateTime? postedAt;
  bool gone = false;

  bool get loading => _ticksLeft != null && _ticksLeft! > 0;
  String? get title => _ticksLeft == null ? titleBefore : (loading ? null : titleAfter);
}

/// The app as the wake sees it. A page is live when it has a webview a reload
/// reaches; any other notification page needs a headless webview, which this
/// host opens and closes like the app does (NOTIF-016).
class _Host implements BackgroundWakeHost {
  _Host(this.pages, {Set<String>? live, this.notificationsOff = const {}})
      : live = live ?? pages.keys.toSet();

  final Map<String, _Page> pages;
  final Set<String> live;
  final Set<String> notificationsOff;
  final Map<String, WakeSkip> blocked = {};
  final Map<String, String> routes = {};
  final Map<String, WakeSkip> refuseOpen = {};
  bool routeApplies = true;
  bool titleThrows = false;
  DateTime _now = DateTime(2026, 9, 26, 12);
  final posts = <String>[];
  final events = <String>[];
  final headless = <String>{};

  @override
  List<WakeCandidate> wakeCandidates() => [
        for (final id in pages.keys)
          WakeCandidate(
            site: WakeSite(siteId: id, name: 'Site $id'),
            notificationsEnabled: !notificationsOff.contains(id),
            live: live.contains(id),
            headlessBlocked: blocked[id],
            route: routes[id],
          ),
      ];

  @override
  Future<void> reload(String siteId) async {
    events.add('reload $siteId');
    pages[siteId]!._ticksLeft = pages[siteId]!.loadTicks;
  }

  @override
  Future<bool> applyRoute(String siteId) async {
    events.add('route $siteId');
    return routeApplies;
  }

  @override
  Future<void> releaseRoute() async => events.add('release route');

  @override
  Future<WakeSkip?> openHeadless(String siteId) async {
    final refused = refuseOpen[siteId];
    if (refused != null) return refused;
    events.add('open $siteId');
    headless.add(siteId);
    pages[siteId]!._ticksLeft = pages[siteId]!.loadTicks;
    return null;
  }

  @override
  Future<void> closeHeadless(String siteId) async {
    events.add('close $siteId');
    headless.remove(siteId);
  }

  bool _reachable(String siteId) =>
      live.contains(siteId) || headless.contains(siteId);

  @override
  bool? isLoading(String siteId) {
    final p = pages[siteId]!;
    return p.gone || !_reachable(siteId) ? null : p.loading;
  }

  @override
  Future<String?> title(String siteId) async {
    if (titleThrows) throw StateError('webview gone mid-read');
    return _reachable(siteId) ? pages[siteId]!.title : null;
  }

  @override
  bool postedSince(String siteId, DateTime since) {
    final at = pages[siteId]!.postedAt;
    return at != null && !at.isBefore(since);
  }

  @override
  Future<void> post({
    required String siteId,
    required String siteName,
    required String body,
  }) async {
    posts.add('$siteName: $body');
  }

  @override
  DateTime now() => _now;

  @override
  Future<void> delay(Duration d) async {
    _now = _now.add(d);
    for (final p in pages.values) {
      if (p._ticksLeft != null && p._ticksLeft! > 0) {
        p._ticksLeft = p._ticksLeft! - 1;
        if (p._ticksLeft == 0 && p.postsOnLoad) p.postedAt = _now;
      }
    }
    events.add('delay ${d.inMilliseconds}');
  }
}

void main() {
  group('unreadCountFromTitle', () {
    test('reads the counts pages put in their titles', () {
      expect(unreadCountFromTitle('(3) WhatsApp'), 3);
      expect(unreadCountFromTitle('Inbox (12) - me@example.com - Gmail'), 12);
      expect(unreadCountFromTitle('(99+) Discord | #general'), 99);
    });

    test('no count, no number', () {
      expect(unreadCountFromTitle('Slack'), isNull);
      expect(unreadCountFromTitle(null), isNull);
      expect(unreadCountFromTitle('Year 2026'), isNull);
    });
  });

  group('NOTIF-014 postsUnreadFallback', () {
    test('a rise with a silent site posts', () {
      expect(postsUnreadFallback(baseline: 2, current: 3, sitePosted: false),
          isTrue);
    });

    test('the site posting itself wins', () {
      expect(postsUnreadFallback(baseline: 2, current: 3, sitePosted: true),
          isFalse);
    });

    test('no rise, or an unknown baseline, posts nothing', () {
      expect(postsUnreadFallback(baseline: 3, current: 3, sitePosted: false),
          isFalse);
      expect(postsUnreadFallback(baseline: 3, current: 1, sitePosted: false),
          isFalse);
      expect(postsUnreadFallback(baseline: null, current: 5, sitePosted: false),
          isFalse);
    });
  });

  group('NOTIF-013 the wake waits for the pages', () {
    test('does not return until reloaded pages have loaded', () async {
      final page = _Page(titleBefore: '(1) Chat', titleAfter: '(1) Chat',
          loadTicks: 6);
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine();
      await engine.wake(host);
      expect(page.loading, isFalse,
          reason: 'returning ends the OS task; a page still loading never '
              'ran its JS');
      expect(host.events.first, 'reload a');
    });

    test('gives up at the settle deadline on a page that never finishes',
        () async {
      final page = _Page(titleBefore: null, titleAfter: null, loadTicks: 1000);
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine();
      final start = host.now();
      await engine.wake(host);
      final spent = host.now().difference(start);
      expect(spent, lessThanOrEqualTo(
          engine.settleDeadline + engine.postGrace + engine.poll));
    });

    test('a webview that goes away mid-wake does not hold it open', () async {
      final page = _Page(titleBefore: null, titleAfter: null, loadTicks: 1000)
        ..gone = true;
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine();
      final start = host.now();
      await engine.wake(host);
      expect(host.now().difference(start),
          lessThan(const Duration(seconds: 5)));
    });
  });

  group('NOTIF-014 the wake posts for a silent site', () {
    test('unread rose and the page said nothing: one post, page title as body',
        () async {
      final page = _Page(titleBefore: '(2) Chat', titleAfter: '(5) Chat');
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine()..noteBaseline('a', '(2) Chat');
      expect((await engine.wake(host)).posted, 1);
      expect(host.posts, ['Site a: (5) Chat']);
    });

    test('the page posted on its own: nothing extra', () async {
      final page = _Page(titleBefore: '(2) Chat', titleAfter: '(5) Chat',
          postsOnLoad: true);
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine()..noteBaseline('a', '(2) Chat');
      expect((await engine.wake(host)).posted, 0);
    });

    test('one rise posts once across wakes', () async {
      final page = _Page(titleBefore: '(2) Chat', titleAfter: '(5) Chat');
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine()..noteBaseline('a', '(2) Chat');
      await engine.wake(host);
      await engine.wake(host);
      expect(host.posts, hasLength(1));
    });

    test('no baseline after a cold launch: records one, posts nothing',
        () async {
      final page = _Page(titleBefore: null, titleAfter: '(5) Chat');
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine();
      expect((await engine.wake(host)).posted, 0);
      expect(engine.baseline('a'), 5);
    });

    test('forget drops sites that are gone', () {
      final engine = BackgroundWakeEngine()
        ..noteBaseline('a', '(1) A')
        ..noteBaseline('b', '(1) B');
      engine.forget({'a'});
      expect(engine.baseline('a'), 1);
      expect(engine.baseline('b'), isNull);
    });
  });

  group('NOTIF-016 a wake checks every notification site', () {
    test('a notification site with no webview is checked headless', () async {
      final page = _Page(titleBefore: null, titleAfter: '(5) Chat');
      final host = _Host({'a': page}, live: {});
      final engine = BackgroundWakeEngine()..noteBaseline('a', '(2) Chat');
      final report = await engine.wake(host);
      expect(report.sites.single.mode, WakeMode.headless,
          reason: 'the wake used to check only sites with a live webview, '
              'so a site evicted or never built was never checked');
      expect(report.sites.single.settle!.kind, WakeSettleKind.loaded);
      expect(host.posts, ['Site a: (5) Chat']);
      expect(host.events.first, 'open a');
      expect(host.events.last, 'close a');
      expect(host.headless, isEmpty);
    });

    test('a process launched for the wake has no webviews: every site is '
        'checked headless, none skipped', () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: '(1) A'),
        'b': _Page(titleBefore: null, titleAfter: '(2) B'),
        'c': _Page(titleBefore: null, titleAfter: null),
      }, live: {});
      final report = await BackgroundWakeEngine().wake(host);
      expect(report.count(WakeMode.headless), 3);
      expect(report.skipped, 0);
    });

    test('live sites reload in place, the rest open headless', () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
        'b': _Page(titleBefore: null, titleAfter: null),
      }, live: {'a'});
      final report = await BackgroundWakeEngine().wake(host);
      expect(host.events.take(2), ['reload a', 'open b']);
      expect([for (final o in report.sites) o.mode],
          [WakeMode.live, WakeMode.headless]);
    });

    test('a site with notifications off is not checked', () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
        'b': _Page(titleBefore: null, titleAfter: null),
      }, live: {}, notificationsOff: {'b'});
      final report = await BackgroundWakeEngine().wake(host);
      expect([for (final o in report.sites) o.site.siteId], ['a']);
      expect(host.events, isNot(contains('open b')));
    });

    test('a site that must not run headless is reported with its reason',
        () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
        'b': _Page(titleBefore: null, titleAfter: null),
      }, live: {})
        ..blocked['b'] = WakeSkip.torDown;
      final report = await BackgroundWakeEngine().wake(host);
      final b = report.sites.firstWhere((o) => o.site.siteId == 'b');
      expect(b.skip, WakeSkip.torDown);
      expect(host.events, isNot(contains('open b')));
      final line = describeWakeSite(b, 2, 2);
      expect(line.normal, 'wake site 2/2 skipped: ${WakeSkip.torDown.reason}');
    });

    test('a headless webview that cannot be built is a skip, not a hang',
        () async {
      final host = _Host({'a': _Page(titleBefore: null, titleAfter: null)},
          live: {})
        ..refuseOpen['a'] = WakeSkip.blockersNotAttached;
      final report = await BackgroundWakeEngine().wake(host);
      expect(report.sites.single.skip, WakeSkip.blockersNotAttached);
      expect(host.events, isNot(contains('close a')));
    });

    test('headless webviews close even when the wake fails', () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
        'b': _Page(titleBefore: null, titleAfter: null),
      }, live: {})
        ..titleThrows = true;
      await expectLater(BackgroundWakeEngine().wake(host), throwsStateError);
      expect(host.headless, isEmpty);
      expect(host.events, containsAll(['close a', 'close b']));
    });

    test('a headless load issued late still gets its start grace', () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null, loadTicks: 1),
        'b': _Page(titleBefore: null, titleAfter: '(1) B', loadTicks: 0),
      }, live: {});
      final report = await BackgroundWakeEngine().wake(host);
      expect(report.sites.map((o) => o.settle!.kind),
          everyElement(isNot(WakeSettleKind.timedOut)));
    });
  });

  group('NOTIF-016 a headless check never goes out through another proxy', () {
    test('with a live site, a headless site on another route is skipped',
        () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
        'b': _Page(titleBefore: null, titleAfter: null),
        'c': _Page(titleBefore: null, titleAfter: null),
      }, live: {'a'})
        ..routes.addAll({'a': 'P', 'b': 'Q', 'c': 'P'});
      final report = await BackgroundWakeEngine().wake(host);
      final byId = {for (final o in report.sites) o.site.siteId: o};
      expect(byId['a']!.mode, WakeMode.live);
      expect(byId['b']!.skip, WakeSkip.proxyConflict);
      expect(byId['c']!.mode, WakeMode.headless);
      expect(host.events.where((e) => e.startsWith('route')), isEmpty,
          reason: 'the live site\'s route is already in force; repointing it '
              'would move the live site too');
    });

    test('with no live site, the first headless route is applied first',
        () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
        'b': _Page(titleBefore: null, titleAfter: null),
      }, live: {})
        ..routes.addAll({'a': 'P', 'b': 'Q'});
      final report = await BackgroundWakeEngine().wake(host);
      expect(host.events.first, 'route a');
      expect(host.events[1], 'open a');
      expect(report.sites[1].skip, WakeSkip.proxyConflict);
      expect(host.events.last, 'release route',
          reason: 'the route goes back to what the loaded sites need once '
              'the headless checks are closed');
    });

    test('a live site without a route does not stop a routed headless site',
        () async {
      // iOS: proxies are per site, but Tor's exit country is one setting.
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
        'tor': _Page(titleBefore: null, titleAfter: null),
      }, live: {'a'})
        ..routes['tor'] = 'exit=<unpinned>';
      final report = await BackgroundWakeEngine().wake(host);
      expect(report.sites[1].mode, WakeMode.headless);
      expect(host.events.first, 'route tor');
    });

    test('a route that will not apply starts no headless load', () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null),
      }, live: {})
        ..routes['a'] = 'P'
        ..routeApplies = false;
      final report = await BackgroundWakeEngine().wake(host);
      expect(report.sites.single.skip, WakeSkip.proxyUnavailable);
      expect(host.events, isNot(contains('open a')));
    });

    test('per-site proxies need no route', () {
      final plan = BackgroundWakeEngine.plan([
        for (final id in ['a', 'b'])
          WakeCandidate(
            site: WakeSite(siteId: id, name: id),
            notificationsEnabled: true,
            live: false,
          ),
      ]);
      expect(plan.routeOwner, isNull);
      expect(plan.entries.map((e) => e.mode), everyElement(WakeMode.headless));
    });
  });

  group('NOTIF-014 baselines outlive the process', () {
    test('a restored baseline posts on the first wake after a relaunch',
        () async {
      final before = BackgroundWakeEngine()..noteBaseline('a', '(2) Chat');
      final kept = before.baselinesOf({'a'});
      final host = _Host({'a': _Page(titleBefore: null, titleAfter: '(4) Chat')},
          live: {});
      final after = BackgroundWakeEngine()..restoreBaselines(kept);
      expect((await after.wake(host)).posted, 1);
      expect(host.posts, ['Site a: (4) Chat']);
    });

    test('only the sites asked for are handed to the store', () {
      final engine = BackgroundWakeEngine()
        ..noteBaseline('a', '(1) A')
        ..noteBaseline('incognito', '(3) B');
      expect(engine.baselinesOf({'a'}), {'a': 1});
    });

    test('a baseline taken in this process beats a restored one', () {
      final engine = BackgroundWakeEngine()
        ..noteBaseline('a', '(7) A')
        ..restoreBaselines({'a': 2});
      expect(engine.baseline('a'), 7);
    });
  });

  group('DEVTOOLS-011 the wake reports what each site did', () {
    test('a load that finished, a page that never loaded, a webview gone',
        () async {
      final host = _Host({
        'a': _Page(titleBefore: '(2) A', titleAfter: '(4) A', loadTicks: 4),
        'b': _Page(titleBefore: null, titleAfter: null, loadTicks: 0),
        'c': _Page(titleBefore: null, titleAfter: null)..gone = true,
      });
      final engine = BackgroundWakeEngine()..noteBaseline('a', '(2) A');
      final report = await engine.wake(host);
      final byId = {for (final o in report.sites) o.site.siteId: o};
      expect(byId['a']!.settle!.kind, WakeSettleKind.loaded);
      expect(byId['a']!.settle!.after, isNotNull);
      expect(byId['a']!.baseline, 2);
      expect(byId['a']!.current, 4);
      expect(byId['a']!.fallbackPosted, isTrue);
      expect(byId['b']!.settle!.kind, WakeSettleKind.neverLoaded);
      expect(byId['c']!.settle!.kind, WakeSettleKind.gone);
      expect(report.posted, 1);
    });

    test('a page still loading at the deadline is reported as such', () async {
      final host = _Host({
        'a': _Page(titleBefore: null, titleAfter: null, loadTicks: 1000),
      });
      final report = await BackgroundWakeEngine().wake(host);
      expect(report.sites.single.settle!.kind, WakeSettleKind.timedOut);
    });

    test('no notification sites: an empty report, nothing reloaded',
        () async {
      final host = _Host({'a': _Page(titleBefore: null, titleAfter: null)},
          notificationsOff: {'a'});
      final report = await BackgroundWakeEngine().wake(host);
      expect(report.sites, isEmpty);
      expect(host.events, isEmpty);
    });

    test('the normal line names no site; the sensitive line does', () async {
      final host = _Host({
        'secret-id': _Page(titleBefore: '(1) Inbox', titleAfter: '(3) Inbox'),
      });
      final engine = BackgroundWakeEngine()..noteBaseline('secret-id', '(1) Inbox');
      final report = await engine.wake(host);
      final line = describeWakeSite(report.sites.single, 1, 1);
      expect(line.normal, contains('wake site 1/1 (live)'));
      expect(line.normal, contains('unread 1 -> 3'));
      expect(line.normal, contains('posted for it'));
      expect(line.normal, isNot(contains('secret-id')));
      expect(line.normal, isNot(contains('Site secret-id')));
      expect(line.normal, isNot(contains('Inbox')));
      expect(line.sensitive, contains('Site secret-id'));
    });
  });
}
