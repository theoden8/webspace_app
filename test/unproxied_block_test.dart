// What the blocked-navigation interstitial says and offers (LEAK-010,
// LEAK-016).
//
// The two assertions that matter are negative: it never offers a way to make
// the request anyway -- a retry included, which BUG-014 measured as a direct
// load -- and it never reads as the proxy having failed or the site being
// unreachable. Those are the two things the copy exists to keep apart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/proxy_coverage_engine.dart';
import 'package:webspace/widgets/unproxied_block.dart';
import 'helpers/localized.dart';

/// The interstitial is a full-screen surface; the default 800x600 test view
/// puts its last button under the fold, where a tap lands on nothing.
void _tallView(WidgetTester t) {
  setViewSize(t, size: const Size(900, 1800));
}

Widget _host(Widget child) => localizedApp(Scaffold(body: child));

void main() {
  testWidgets('names the site and the destination it did not request',
      (t) async {
    await t.pumpWidget(_host(UnproxiedNavigationBlock(
      siteName: 'Acme Bank',
      blocked: (url: 'https://tracker.example.org/a/b?c=1', why: const Unprovable()),
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
      blocked: (url: 'https://example.org/', why: const Unprovable()),
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
      blocked: (url: 'https://example.org/', why: const Unprovable()),
      onGoBack: () {},
      onOpenProxySettings: () {},
    )));

    // Two actions, and neither reaches the destination. A third button on
    // this screen is how a bypass would arrive -- including a retry, which
    // BUG-014 once measured as a direct load rather than a
    // proxied one.
    expect(
      find.byWidgetPredicate((w) => w is ButtonStyleButton),
      findsNWidgets(2),
    );
  });

  testWidgets('LEAK-016: an onion block says the site needs a proxy',
      (t) async {
    _tallView(t);
    const onion =
        'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';
    var settings = 0;
    await t.pumpWidget(_host(UnproxiedNavigationBlock(
      siteName: 'Forum',
      blocked: (url: 'http://$onion/thread/1', why: const OnionNeedsProxy()),
      onGoBack: () {},
      onOpenProxySettings: () => settings++,
    )));

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.onionBlockBody('Forum')), findsOneWidget);
    expect(find.text(loc.onionBlockWhy), findsOneWidget);
    expect(find.text(loc.unproxiedBlockBody('Forum')), findsNothing,
        reason: 'the site has no proxy, so the copy that says it has one '
            'would be false');
    expect(find.textContaining(onion), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is ButtonStyleButton),
      findsNWidgets(2),
    );
    await t.tap(find.text(loc.unproxiedBlockProxySettings));
    expect(settings, 1);
  });

  test('the copy says nothing failed, because nothing was tried', () async {
    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    final copy = [
      loc.unproxiedBlockTitle,
      loc.unproxiedBlockBody('Acme'),
      loc.unproxiedBlockWhy,
      loc.onionBlockBody('Acme'),
      loc.onionBlockWhy,
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
