// What the blocked-navigation interstitial says and offers (LEAK-010).
//
// The two assertions that matter are negative: it never offers a way to make
// the request anyway -- a retry included, which BUG-014 measured as a direct
// load -- and it never reads as the proxy having failed or the site being
// unreachable. Those are the two things the copy exists to keep apart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/unproxied_block.dart';

/// The interstitial is a full-screen surface; the default 800x600 test view
/// puts its last button under the fold, where a tap lands on nothing.
void _tallView(WidgetTester t) {
  t.view.physicalSize = const Size(900, 1800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('names the site and the destination it did not request',
      (t) async {
    await t.pumpWidget(_host(UnproxiedNavigationBlock(
      siteName: 'Acme Bank',
      blockedUrl: 'https://tracker.example.org/a/b?c=1',
      onGoBack: () {},
      onOpenProxySettings: () {},
    )));

    expect(find.textContaining('Acme Bank'), findsOneWidget);
    expect(find.textContaining('tracker.example.org'), findsOneWidget);
  });

  testWidgets('offers going back and the setting that caused it', (t) async {
    _tallView(t);
    var back = 0;
    var settings = 0;
    await t.pumpWidget(_host(UnproxiedNavigationBlock(
      siteName: 'Acme',
      blockedUrl: 'https://example.org/',
      onGoBack: () => back++,
      onOpenProxySettings: () => settings++,
    )));

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    await t.tap(find.text(loc.unproxiedBlockBack));
    await t.tap(find.text(loc.unproxiedBlockProxySettings));
    expect([back, settings], [1, 1]);
  });

  testWidgets('offers nothing that makes the request anyway', (t) async {
    _tallView(t);
    await t.pumpWidget(_host(UnproxiedNavigationBlock(
      siteName: 'Acme',
      blockedUrl: 'https://example.org/',
      onGoBack: () {},
      onOpenProxySettings: () {},
    )));

    // Two actions, and neither reaches the destination. A third button on
    // this screen is how a bypass would arrive -- including a retry, which
    // BUG-014 attempts 90-92 measured as a direct load rather than a
    // proxied one.
    expect(
      find.byWidgetPredicate((w) => w is ButtonStyleButton),
      findsNWidgets(2),
    );
  });

  test('the copy says nothing failed, because nothing was tried', () async {
    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    final copy = [
      loc.unproxiedBlockTitle,
      loc.unproxiedBlockBody('Acme'),
      loc.unproxiedBlockWhy,
    ].join(' ').toLowerCase();

    for (final forbidden in [
      'failed',
      'failure',
      'offline',
      'unavailable',
      'error',
      'try again anyway',
    ]) {
      expect(copy.contains(forbidden), isFalse,
          reason: 'the request was never made, so "$forbidden" describes '
              'something that did not happen');
    }
  });
}
