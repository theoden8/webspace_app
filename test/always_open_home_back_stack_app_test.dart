import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/webspace_page.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// Always open Home sends a site's tab home in place on a fresh entry: the
/// tab keeps its id, so the back stack saved for it is still the page it was
/// left on, and restoring it over the home page puts that page back (#1046).
void main() {
  const home = 'https://bank.example.test/login';

  Future<_ReadsLogged> savedStack(WebViewModel site) async {
    final state = _ReadsLogged();
    debugWebViewStateStorageOverride = state;
    addTearDown(() => debugWebViewStateStorageOverride = null);
    await state.saveState(site.activeStateKey,
        state: Uint8List.fromList([1, 2, 3]));
    return state;
  }

  Future<void> openBank(WidgetTester tester) async {
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Bank');
  }

  for (final tabsEnabled in [true, false]) {
    testWidgets(
        'a cold start opens an Always open Home site at home, restoring no '
        'back stack (AOH-002, TAB-014, tabs ${tabsEnabled ? 'on' : 'off'})',
        (tester) async {
      final site = WebViewModel(
        initUrl: home,
        name: 'Bank',
        alwaysOpenHome: true,
        tabsEnabled: tabsEnabled,
      );
      final state = await savedStack(site);

      await pumpRealApp(tester, sites: [site]);
      await openBank(tester);

      final view =
          tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
      expect(view.platform.params.initialUrlRequest?.url.toString(), home);
      expect(state.reads, isNotEmpty, reason: 'the activation reads its tab');
      expect(state.reads.values.whereType<Uint8List>(), isEmpty,
          reason: 'the saved back stack is the page the site was left on');
    });
  }

  testWidgets('a site without Always open Home opened from the app after a '
      'cold start is where it was left (HS-006)', (tester) async {
    final site = WebViewModel(initUrl: home, name: 'Bank');
    final state = await savedStack(site);

    await pumpRealApp(tester, sites: [site]);
    await openBank(tester);

    expect(state.reads[site.activeStateKey], [1, 2, 3]);
  });
}

/// What each read of a key answered last.
class _ReadsLogged extends InMemoryWebViewStateStorage {
  final Map<String, Uint8List?> reads = {};

  @override
  Future<Uint8List?> loadState(String key) async =>
      reads[key] = await super.loadState(key);
}
