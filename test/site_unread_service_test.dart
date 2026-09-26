import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_unread_service.dart';
import 'package:webspace/widgets/site_unread_badge.dart';

void main() {
  group('counting (UNREAD-001)', () {
    test('a post while the site is off screen is counted', () {
      final unread = SiteUnreadService.forTest()..isOnScreen = (_) => false;
      unread.recordNotification('a');
      unread.recordNotification('a');
      expect(unread.count('a'), 2);
      expect(unread.count('b'), 0);
    });

    test('a post from the site on screen is already seen', () {
      final unread = SiteUnreadService.forTest()..isOnScreen = (id) => id == 'a';
      unread.recordNotification('a');
      unread.recordNotification('b');
      expect(unread.count('a'), 0);
      expect(unread.count('b'), 1);
    });

    test('a tagged post replaces the site\'s earlier post with that tag', () {
      final unread = SiteUnreadService.forTest();
      var changes = 0;
      unread.addListener(() => changes++);
      unread.recordNotification('a', tag: 'inbox');
      unread.recordNotification('a', tag: 'inbox');
      unread.recordNotification('a', tag: 'mentions');
      unread.recordNotification('a', tag: '');
      expect(unread.count('a'), 3);
      expect(changes, 3);
    });

    test('looking at the site clears them', () {
      final unread = SiteUnreadService.forTest();
      unread.recordNotification('a', tag: 'inbox');
      unread.recordNotification('a');
      unread.markSeen('a');
      expect(unread.count('a'), 0);
      unread.recordNotification('a', tag: 'inbox');
      expect(unread.count('a'), 1);
    });

    test('anyUnread reads only the sites it is given', () {
      final unread = SiteUnreadService.forTest();
      unread.recordNotification('a');
      expect(unread.anyUnread(['a', 'b']), isTrue);
      expect(unread.anyUnread(['b']), isFalse);
    });
  });

  group('forgetting a site (UNREAD-003)', () {
    test('forget and retainOnly drop every trace', () {
      final unread = SiteUnreadService.forTest();
      unread.recordNotification('a');
      unread.recordNotification('b', tag: 'inbox');
      unread.recordNotification('c');
      unread.forget('a');
      unread.retainOnly({'c'});
      expect(unread.count('a'), 0);
      expect(unread.count('b'), 0);
      expect(unread.count('c'), 1);
    });

    test('nothing is announced for a change that changes nothing', () {
      final unread = SiteUnreadService.forTest();
      unread.recordNotification('c');
      var changes = 0;
      unread.addListener(() => changes++);
      unread.markSeen('a');
      unread.forget('a');
      unread.retainOnly({'c'});
      expect(changes, 0);
    });
  });

  group('badge widgets (UNREAD-002)', () {
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
      for (var i = 0; i < 120; i++) {
        unread.recordNotification('a');
      }
      await tester.pump();
      expect(find.text('99+'), findsOneWidget);
      unread.markSeen('a');
      await tester.pump();
      expect(find.byType(Badge), findsNothing);
    });

    testWidgets('the pill is labelled from the settings string',
        (tester) async {
      final handle = tester.ensureSemantics();
      final unread = SiteUnreadService.forTest();
      for (var i = 0; i < 3; i++) {
        unread.recordNotification('a');
      }
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
