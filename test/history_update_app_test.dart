import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// A page that restates its own URL through `history.replaceState` (some do
/// on every keystroke) moves nothing the app shows or keeps, and every site
/// written to disk per event ran on the thread the webview takes input on.
/// A page that does move keeps having its URL saved.
void main() {
  const search = 'https://mail.example.test/search';

  testWidgets('a history update to the same URL writes nothing; a new one is saved',
      (tester) async {
    await pumpRealApp(tester, sites: [
      WebViewModel(initUrl: 'https://mail.example.test', name: 'Mail'),
      WebViewModel(initUrl: 'https://news.example.test', name: 'News'),
    ]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Mail');
    await attachWebViews(tester);
    await pageHistoryChanged(tester, url: search);
    await settleRealApp(tester);

    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    final written = prefs!.getStringList('webViewModels');
    expect(written!.first, contains(search));
    await tester.runAsync(() => prefs.setStringList('webViewModels', ['untouched']));

    for (var i = 0; i < 5; i++) {
      await pageHistoryChanged(tester, url: search);
    }
    await settleRealApp(tester);
    expect(prefs.getStringList('webViewModels'), ['untouched']);

    await pageHistoryChanged(tester, url: '$search?q=a');
    await settleRealApp(tester);
    expect(prefs.getStringList('webViewModels')!.first, contains('$search?q=a'));
  });
}
