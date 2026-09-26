import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_unread_service.dart';
import 'package:webspace/widgets/site_unread_badge.dart';

void main() {
  group('unreadCountFromTitle (UNREAD-001)', () {
    test('a leading count', () {
      expect(unreadCountFromTitle('(3) Messenger'), 3);
      expect(unreadCountFromTitle('(12)Chat'), 12);
      expect(unreadCountFromTitle('  (1) Home / X'), 1);
    });

    test('a count closing the first segment', () {
      expect(unreadCountFromTitle('Inbox (3) - user@example.com - Mail'), 3);
      expect(unreadCountFromTitle('Chat (4) | Workspace'), 4);
      expect(unreadCountFromTitle('Messages (5)'), 5);
    });

    test('a capped or grouped count', () {
      expect(unreadCountFromTitle('(99+) Forum'), 99);
      expect(unreadCountFromTitle('Inbox (1,234) - Mail'), 1234);
      expect(unreadCountFromTitle('(1.234) Posteingang'), 1234);
    });

    test('an explicit zero is a count', () {
      expect(unreadCountFromTitle('(0) Messenger'), 0);
    });

    test('a number that is part of the page name is not a count', () {
      expect(unreadCountFromTitle(null), isNull);
      expect(unreadCountFromTitle(''), isNull);
      expect(unreadCountFromTitle('Messenger'), isNull);
      expect(unreadCountFromTitle('Apollo 11 (1969 film) - Wikipedia'), isNull);
      expect(unreadCountFromTitle('Top 10 - News (2) - Site'), isNull);
      expect(unreadCountFromTitle('News - Site (2)'), isNull);
      expect(unreadCountFromTitle('Page(2)'), isNull);
    });
  });

  group('page count (UNREAD-002)', () {
    test('a stated count shows at once and moves with the title', () {
      final unread = SiteUnreadService.forTest();
      unread.onTitleChanged('a', '(2) Chat');
      expect(unread.pageCount('a'), 2);
      unread.onTitleChanged('a', '(5) Chat');
      expect(unread.count('a'), 5);
    });

    test('a title without a count clears only once it has held', () {
      fakeAsync((async) {
        final unread = SiteUnreadService.forTest();
        unread.onTitleChanged('a', '(2) Chat');
        unread.onTitleChanged('a', 'Chat');
        async.elapse(SiteUnreadService.clearDelay - const Duration(milliseconds: 1));
        expect(unread.pageCount('a'), 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(unread.pageCount('a'), 0);
      });
    });

    test('a title that alternates with a message line does not blink', () {
      fakeAsync((async) {
        final unread = SiteUnreadService.forTest();
        var changes = 0;
        unread.addListener(() => changes++);
        unread.onTitleChanged('a', '(1) Chat');
        for (var i = 0; i < 20; i++) {
          async.elapse(const Duration(seconds: 1));
          unread.onTitleChanged('a', 'Alice sent a message');
          async.elapse(const Duration(seconds: 1));
          unread.onTitleChanged('a', '(1) Chat');
        }
        expect(unread.pageCount('a'), 1);
        expect(changes, 1);
      });
    });

    test('a later title without a count does not extend a pending clear', () {
      fakeAsync((async) {
        final unread = SiteUnreadService.forTest();
        unread.onTitleChanged('a', '(2) Chat');
        unread.onTitleChanged('a', 'Chat');
        async.elapse(const Duration(seconds: 3));
        unread.onTitleChanged('a', 'Chat - Settings');
        async.elapse(SiteUnreadService.clearDelay - const Duration(seconds: 3));
        expect(unread.pageCount('a'), 0);
      });
    });

    test('an explicit zero clears at once', () {
      fakeAsync((async) {
        final unread = SiteUnreadService.forTest();
        unread.onTitleChanged('a', '(2) Chat');
        unread.onTitleChanged('a', 'Chat');
        unread.onTitleChanged('a', '(0) Chat');
        expect(unread.pageCount('a'), 0);
        async.elapse(SiteUnreadService.clearDelay);
        expect(unread.pageCount('a'), 0);
      });
    });

    test('a disposed page takes its count with it', () {
      fakeAsync((async) {
        final unread = SiteUnreadService.forTest();
        unread.onTitleChanged('a', '(2) Chat');
        unread.onTitleChanged('a', 'Chat');
        unread.clearPageCount('a');
        expect(unread.pageCount('a'), 0);
        unread.onTitleChanged('a', '(4) Chat');
        async.elapse(SiteUnreadService.clearDelay);
        expect(unread.pageCount('a'), 4);
      });
    });

    test('opening the site leaves the page count alone', () {
      final unread = SiteUnreadService.forTest();
      unread.onTitleChanged('a', '(2) Chat');
      unread.markSeen('a');
      expect(unread.count('a'), 2);
    });
  });

  group('missed notifications (UNREAD-003)', () {
    test('a post while the site is off screen is counted', () {
      final unread = SiteUnreadService.forTest()..isOnScreen = (_) => false;
      unread.recordNotification('a');
      unread.recordNotification('a');
      expect(unread.missedCount('a'), 2);
      expect(unread.missedCount('b'), 0);
    });

    test('a post from the site on screen is already seen', () {
      final unread = SiteUnreadService.forTest()..isOnScreen = (id) => id == 'a';
      unread.recordNotification('a');
      unread.recordNotification('b');
      expect(unread.missedCount('a'), 0);
      expect(unread.missedCount('b'), 1);
    });

    test('a tagged post replaces the site\'s earlier post with that tag', () {
      final unread = SiteUnreadService.forTest();
      var changes = 0;
      unread.addListener(() => changes++);
      unread.recordNotification('a', tag: 'inbox');
      unread.recordNotification('a', tag: 'inbox');
      unread.recordNotification('a', tag: 'mentions');
      unread.recordNotification('a', tag: '');
      expect(unread.missedCount('a'), 3);
      expect(changes, 3);
    });

    test('looking at the site clears them', () {
      final unread = SiteUnreadService.forTest();
      unread.recordNotification('a', tag: 'inbox');
      unread.recordNotification('a');
      unread.markSeen('a');
      expect(unread.missedCount('a'), 0);
      unread.recordNotification('a', tag: 'inbox');
      expect(unread.missedCount('a'), 1);
    });
  });

  group('badge count (UNREAD-004)', () {
    test('the page count wins over missed notifications', () {
      final unread = SiteUnreadService.forTest();
      unread.recordNotification('a');
      expect(unread.count('a'), 1);
      unread.onTitleChanged('a', '(7) Chat');
      expect(unread.count('a'), 7);
    });

    test('anyUnread reads only the sites it is given', () {
      final unread = SiteUnreadService.forTest();
      unread.recordNotification('a');
      expect(unread.anyUnread(['a', 'b']), isTrue);
      expect(unread.anyUnread(['b']), isFalse);
    });
  });

  group('forgetting a site (UNREAD-005)', () {
    test('forget and retainOnly drop every trace', () {
      fakeAsync((async) {
        final unread = SiteUnreadService.forTest();
        unread.onTitleChanged('a', '(2) Chat');
        unread.onTitleChanged('a', 'Chat');
        unread.recordNotification('a');
        unread.onTitleChanged('b', '(1) Mail');
        unread.recordNotification('c');
        unread.forget('a');
        unread.retainOnly({'c'});
        async.elapse(SiteUnreadService.clearDelay);
        expect(unread.count('a'), 0);
        expect(unread.count('b'), 0);
        expect(unread.count('c'), 1);
      });
    });

    test('nothing is announced for a change that changes nothing', () {
      final unread = SiteUnreadService.forTest();
      var changes = 0;
      unread.addListener(() => changes++);
      unread.markSeen('a');
      unread.forget('a');
      unread.clearPageCount('a');
      unread.onTitleChanged('a', 'Chat');
      unread.onTitleChanged('a', '(0) Chat');
      expect(changes, 0);
    });
  });

  group('badge widgets (UNREAD-004)', () {
    Widget app(Widget child) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Center(child: child)),
        );

    testWidgets('no pill and no room while nothing is unread', (tester) async {
      final unread = SiteUnreadService.forTest();
      await tester.pumpWidget(app(SiteUnreadBadge(
        siteId: 'a',
        service: unread,
        padding: const EdgeInsets.all(20),
      )));
      expect(find.byType(Badge), findsNothing);
      expect(tester.getSize(find.byType(SiteUnreadBadge)), Size.zero);
    });

    testWidgets('the pill follows the count without a parent rebuild',
        (tester) async {
      final unread = SiteUnreadService.forTest();
      await tester.pumpWidget(app(SiteUnreadBadge(siteId: 'a', service: unread)));
      unread.recordNotification('a');
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      unread.onTitleChanged('a', '(250) Chat');
      await tester.pump();
      expect(find.text('99+'), findsOneWidget);
      unread.forget('a');
      await tester.pump();
      expect(find.byType(Badge), findsNothing);
    });

    testWidgets('the pill is labelled from the settings string',
        (tester) async {
      final handle = tester.ensureSemantics();
      final unread = SiteUnreadService.forTest();
      unread.onTitleChanged('a', '(3) Chat');
      await tester.pumpWidget(app(SiteUnreadBadge(siteId: 'a', service: unread)));
      final loc = AppLocalizations.of(tester.element(find.byType(SiteUnreadBadge)));
      expect(find.bySemanticsLabel(siteUnreadBadgeLabel(loc, 3)), findsOneWidget);
      expect(siteUnreadBadgeLabel(loc, 3),
          '${loc.siteSettingsNotifications}: 3');
      handle.dispose();
    });

    testWidgets('the menu glyph carries a dot only for the sites it watches',
        (tester) async {
      final unread = SiteUnreadService.forTest();
      await tester.pumpWidget(app(UnreadMenuIcon(siteIds: const ['b'], service: unread)));
      expect(find.byIcon(Icons.menu), findsOneWidget);
      bool dot() => tester.widget<Badge>(find.byType(Badge)).isLabelVisible;
      expect(dot(), isFalse);
      unread.recordNotification('a');
      await tester.pump();
      expect(dot(), isFalse);
      unread.recordNotification('b');
      await tester.pump();
      expect(dot(), isTrue);
      expect(find.byIcon(Icons.menu), findsOneWidget);
    });
  });
}
