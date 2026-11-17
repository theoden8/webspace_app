import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/tab_offer_origin.dart';
import 'package:webspace/widgets/toast_page_boundary.dart';

void main() {
  test('a delayed tab confirmation follows its source page', () async {
    final site = Object();
    final otherSite = Object();
    final origin = TabOfferOrigin(
      site: site,
      tab: 'tab 1',
      activationVersion: 1,
    );
    final commit = Completer<void>();
    Object? shownSite = site;
    Object? shownTab = 'tab 1';

    Future<bool> finishOffer() async {
      await commit.future;
      return origin.stillVisible(
        shownSite: shownSite,
        shownTab: shownTab,
        offerSite: site,
        currentActivationVersion: 1,
      );
    }

    final pending = finishOffer();
    shownSite = otherSite;
    commit.complete();
    expect(await pending, isFalse);

    expect(
      origin.stillVisible(
        shownSite: site,
        shownTab: 'tab 2',
        offerSite: site,
        currentActivationVersion: 1,
      ),
      isFalse,
    );
    expect(
      origin.stillVisible(
        shownSite: site,
        shownTab: 'tab 1',
        offerSite: site,
        currentActivationVersion: 1,
      ),
      isTrue,
    );
    expect(
      origin.stillVisible(
        shownSite: site,
        shownTab: 'tab 1',
        offerSite: site,
        currentActivationVersion: 3,
      ),
      isFalse,
      reason: 'switching away and back invalidates the old offer',
    );
  });

  testWidgets(
    'site, tab, or tab-list changes dismiss visible and queued snackbars',
    (tester) async {
      final boundary = ToastPageBoundary();
      final siteA = Object();
      final siteB = Object();
      late ScaffoldMessengerState messenger;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                messenger = ScaffoldMessenger.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      void show(String message) => messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(minutes: 1)),
      );
      void follow(
        Object? site, {
        required Object? tab,
        Object? scope,
        List<String> tabs = const ['tab 1', 'tab 2'],
      }) => boundary.follow(
        site: site,
        tab: tab,
        scope: scope,
        tabs: tabs,
        messenger: messenger,
      );

      follow(siteA, tab: 'tab 1');
      show('first');
      show('queued');
      await tester.pump();
      expect(find.text('first'), findsOneWidget);

      follow(siteA, tab: 'tab 1');
      await tester.pump();
      expect(find.text('first'), findsOneWidget);

      follow(siteA, tab: 'tab 2');
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);

      follow(siteA, tab: 'tab 2', tabs: const ['tab 1', 'tab 2', 'tab 3']);
      show('opened tab 3');
      await tester.pump();
      expect(find.text('opened tab 3'), findsOneWidget);
      follow(siteA, tab: 'tab 2'); // The background tab was closed.
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);

      show('second site');
      await tester.pump();
      follow(siteB, tab: 'tab 1');
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);

      follow(siteB, tab: 'tab 1', scope: 'one');
      show('first webspace');
      await tester.pump();
      follow(siteB, tab: 'tab 1', scope: 'two');
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('a message posted just after a switch belongs to the new page', (
    tester,
  ) async {
    final boundary = ToastPageBoundary();
    final first = Object();
    final second = Object();
    late ScaffoldMessengerState messenger;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              messenger = ScaffoldMessenger.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    void show(String message) => messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(minutes: 1)),
    );
    void follow(Object site) => boundary.follow(
      site: site,
      tab: 'tab',
      scope: null,
      tabs: const ['tab'],
      messenger: messenger,
    );

    follow(first);
    show('old page');
    await tester.pump();
    follow(second);
    show('new page');
    await tester.pump();
    expect(find.text('old page'), findsNothing);
    expect(find.text('new page'), findsOneWidget);

    // A redundant rebuild must not erase the new page's message.
    follow(second);
    await tester.pump();
    expect(find.text('new page'), findsOneWidget);

    // Two quick switches must not revive a queued message from either page.
    show('queued on second');
    follow(first);
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });
}
