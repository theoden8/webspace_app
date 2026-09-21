// What the blocked-navigation interstitial says and offers (LEAK-010).
//
// The two assertions that matter are negative: it never offers a way to make
// the request anyway, and it never reads as the proxy having failed or the
// site being unreachable. Those are the two things the copy exists to keep
// apart.

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
      onRetry: () {},
      onOpenProxySettings: () {},
    )));

    expect(find.textContaining('Acme Bank'), findsOneWidget);
    expect(find.textContaining('tracker.example.org'), findsOneWidget);
  });

  testWidgets('offers going back, reopening through the proxy, and the '
      'setting that caused it', (t) async {
    _tallView(t);
    var back = 0;
    var retry = 0;
    var settings = 0;
    await t.pumpWidget(_host(UnproxiedNavigationBlock(
      siteName: 'Acme',
      blockedUrl: 'https://example.org/',
      onGoBack: () => back++,
      onRetry: () => retry++,
      onOpenProxySettings: () => settings++,
    )));

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    await t.tap(find.text(loc.unproxiedBlockBack));
    await t.tap(find.text(loc.unproxiedBlockReopen));
    await t.tap(find.text(loc.unproxiedBlockProxySettings));
    expect([back, retry, settings], [1, 1, 1]);
  });

  testWidgets('offers nothing that makes the request anyway', (t) async {
    _tallView(t);
    await t.pumpWidget(_host(UnproxiedNavigationBlock(
      siteName: 'Acme',
      blockedUrl: 'https://example.org/',
      onGoBack: () {},
      onRetry: () {},
      onOpenProxySettings: () {},
    )));

    // Three actions, and each one is either a way out or a way to do it
    // properly. A fourth button on this screen is how a bypass would arrive.
    expect(
      find.byWidgetPredicate((w) => w is ButtonStyleButton),
      findsNWidgets(3),
    );
  });

  test('the copy says nothing failed, because nothing was tried', () async {
    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    final copy = [
      loc.unproxiedBlockTitle,
      loc.unproxiedBlockBody('Acme'),
      loc.unproxiedBlockWhy,
      loc.unproxiedBlockReopen,
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
