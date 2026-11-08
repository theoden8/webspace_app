import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/settings/shim_group.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

const _light = 'https://light.example/';
const _follows = 'https://follows.example/';

/// The theme the webview built to open [url] was last told after it was
/// built, read off the shim's config, or null if it was told none.
String? _lastTheme(String url) {
  final told = [
    for (final s in webViewUserScripts[url] ?? const [])
      if (s.groupName == ShimGroup.themeColorScheme.groupName) s.source,
  ];
  if (told.isEmpty) return null;
  return RegExp(r'"theme":"(\w+)"').firstMatch(told.last)?.group(1);
}

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));

  testWidgets(
      'HINTS-003: a theme picked in App Settings reaches every open webview '
      'that follows the app, and a site with its own keeps it', (tester) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(initUrl: _light, name: 'Light', theme: WebViewTheme.light),
        WebViewModel(initUrl: _follows, name: 'Follows'),
      ],
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Light');
    await attachWebViews(tester);
    await openSiteFromDrawer(tester, name: 'Follows');
    await attachWebViews(tester);
    expect(webViewUserScripts.keys, containsAll([_light, _follows]),
        reason: 'both sites have a live webview');
    webViewUserScripts.clear();

    await tester.tap(find.byTooltip('Open navigation menu'));
    await settleRealApp(tester);
    await tester.tap(find.text('Back to Webspaces'));
    await settleRealApp(tester);
    await tester.tap(find.byTooltip('App Settings'));
    await settleRealApp(tester);
    await tester.tap(find.text('Appearance'));
    await settleRealApp(tester);
    await tester.tap(find.text('Dark'));
    await settleRealApp(tester);

    expect(_lastTheme(_follows), 'dark');
    expect(_lastTheme(_light), 'light');
  });

  testWidgets('HINTS-003: a page load tells the page the theme again',
      (tester) async {
    await pumpRealApp(
      tester,
      sites: [WebViewModel(initUrl: _follows, name: 'Follows')],
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Follows');
    await attachWebViews(tester);
    webViewUserScripts.clear();

    await pageHistoryChanged(tester, url: '${_follows}next');
    await settleRealApp(tester);

    expect(_lastTheme(_follows), isNotNull);
  });
}
