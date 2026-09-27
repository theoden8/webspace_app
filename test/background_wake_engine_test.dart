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

class _Host implements BackgroundWakeHost {
  _Host(this.pages);

  final Map<String, _Page> pages;
  DateTime _now = DateTime(2026, 9, 26, 12);
  final posts = <String>[];
  final events = <String>[];

  @override
  List<WakeSite> wakeSites() => [
        for (final id in pages.keys) WakeSite(siteId: id, name: 'Site $id'),
      ];

  @override
  Future<void> reload(String siteId) async {
    events.add('reload $siteId');
    pages[siteId]!._ticksLeft = pages[siteId]!.loadTicks;
  }

  @override
  bool? isLoading(String siteId) {
    final p = pages[siteId]!;
    return p.gone ? null : p.loading;
  }

  @override
  Future<String?> title(String siteId) async => pages[siteId]!.title;

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
      expect(await engine.wake(host), 1);
      expect(host.posts, ['Site a: (5) Chat']);
    });

    test('the page posted on its own: nothing extra', () async {
      final page = _Page(titleBefore: '(2) Chat', titleAfter: '(5) Chat',
          postsOnLoad: true);
      final host = _Host({'a': page});
      final engine = BackgroundWakeEngine()..noteBaseline('a', '(2) Chat');
      expect(await engine.wake(host), 0);
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
      expect(await engine.wake(host), 0);
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
}
