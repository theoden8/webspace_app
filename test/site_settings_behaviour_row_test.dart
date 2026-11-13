import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/no_shortcuts.dart';
import 'helpers/localized.dart';

Future<void> _pump(WidgetTester tester, {required WebViewModel model}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    localizedApp(KeyedSubtree(
        key: UniqueKey(),
        child: SettingsScreen(
          webViewModel: model,
          appTheme: WebViewTheme.system,
          isolation: fakeSharedJar(),
        ),
      )),
  );
  await tester.pumpAndSettle();
}

String _behaviourSummary(WidgetTester tester) {
  final row = find.ancestor(
    of: find.text('Behaviour'),
    matching: find.byType(ListTile),
  );
  final tile = tester.widget<ListTile>(row);
  return (tile.subtitle! as Text).data!;
}

/// [model]'s Behaviour row summary, read off a fresh settings screen.
Future<String> _summaryOf(
  WidgetTester tester, {
  required WebViewModel model,
}) async {
  await _pump(tester, model: model);
  return _behaviourSummary(tester);
}

WebViewModel _site({
  bool kioskMode = false,
  bool fullscreenMode = false,
  bool alwaysOpenHome = false,
  bool incognito = false,
  ExternalLinkMode externalLinkMode = ExternalLinkMode.inApp,
}) => WebViewModel(
  initUrl: 'https://example.com/',
  kioskMode: kioskMode,
  fullscreenMode: fullscreenMode,
  alwaysOpenHome: alwaysOpenHome,
  incognito: incognito,
  externalLinkMode: externalLinkMode,
);

/// The site's Behaviour row names what is on (BEHAV-002), and Kiosk mode only
/// where a shortcut launch, the one thing it decides, can happen (KIOSK-006).
void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  WebViewModel kioskSite() =>
      WebViewModel(initUrl: 'https://example.com/', kioskMode: true);

  testWidgets('the Behaviour row names a kiosk site', (tester) async {
    await _pump(tester, model: kioskSite());
    expect(_behaviourSummary(tester), contains('Kiosk mode'));
  });

  testWidgets('where no shortcut can be added, as on a TV, the Behaviour '
      'row does not name a stored kiosk (KIOSK-006)', (tester) async {
    withoutShortcuts();
    await _pump(tester, model: kioskSite());
    expect(_behaviourSummary(tester), isNot(contains('Kiosk mode')));
  });

  testWidgets('BEHAV-002: a site with nothing on reads Nothing enabled', (
    tester,
  ) async {
    expect(await _summaryOf(tester, model: _site()), 'Nothing enabled');
  });

  testWidgets('BEHAV-002: the row names the one switch that is on', (
    tester,
  ) async {
    expect(
      await _summaryOf(tester, model: _site(kioskMode: true)),
      'Kiosk mode',
    );
  });

  testWidgets('BEHAV-002: External links outside the default count as on', (
    tester,
  ) async {
    expect(
      await _summaryOf(
        tester,
        model: _site(externalLinkMode: ExternalLinkMode.block),
      ),
      'Block external links',
    );
    expect(
      await _summaryOf(
        tester,
        model: _site(externalLinkMode: ExternalLinkMode.browser),
      ),
      'Open external links in browser',
    );
  });

  testWidgets(
    'BEHAV-002: Always open Home counts as on while incognito forces it',
    (tester) async {
      expect(
        await _summaryOf(tester, model: _site(incognito: true)),
        'Always open Home',
      );
    },
  );

  testWidgets('BEHAV-002: past two names the rest is a count', (tester) async {
    final summary = await _summaryOf(
      tester,
      model: _site(alwaysOpenHome: true, kioskMode: true, fullscreenMode: true),
    );
    expect(summary, startsWith('Always open Home'));
    expect(summary, contains('Kiosk mode'));
    expect(summary, isNot(contains('Full')));
    expect(summary, endsWith('1 more'));
  });
}
