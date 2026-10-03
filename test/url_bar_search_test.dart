import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/url_bar.dart';

const _ddg = UrlBarSearchSite('ddg', 'DuckDuckGo');
const _kagi = UrlBarSearchSite('kagi', 'Kagi');

/// LIR-033: the magnifier turns the URL bar into a search field, and words
/// typed as an address search too.
void main() {
  late List<(String, String?)> searches;
  late List<String> opened;

  Future<void> pumpBar(
    WidgetTester tester, {
    List<UrlBarSearchSite> sites = const [_ddg, _kagi],
    String? defaultId,
    bool canSearch = true,
  }) async {
    searches = [];
    opened = [];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox()),
            UrlBar(
              currentUrl: 'https://github.com/theoden8',
              onUrlSubmitted: (url) => opened.add(url),
              onSiteInfo: () {},
              searchSites: sites,
              defaultSearchSiteId: defaultId,
              onSearch: canSearch
                  ? (query, siteId) => searches.add((query, siteId))
                  : null,
            ),
          ],
        ),
      ),
    ));
  }

  String shown(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  String? hint(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText;

  Finder magnifier() => find.byTooltip('Web search');

  testWidgets('the magnifier turns the bar into a search field on the default',
      (tester) async {
    await pumpBar(tester, defaultId: 'kagi');
    expect(magnifier(), findsOneWidget);
    await tester.tap(magnifier());
    await tester.pump();
    expect(shown(tester), isEmpty);
    expect(hint(tester), 'Search with Kagi');
    await tester.enterText(find.byType(TextField), 'github.com');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(searches, [('github.com', 'kagi')],
        reason: 'in search mode even an address is searched');
    expect(opened, isEmpty);
    expect(shown(tester), 'https://github.com/theoden8');
  });

  testWidgets('words typed as an address search with the default',
      (tester) async {
    await pumpBar(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'flutter hot reload');
    await tester.pump();
    expect(find.byTooltip('Search with DuckDuckGo'), findsOneWidget,
        reason: 'the button says Enter will search');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(searches, [('flutter hot reload', 'ddg')]);
    expect(opened, isEmpty);
  });

  testWidgets('an address still opens', (tester) async {
    await pumpBar(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'codeberg.org/theoden8');
    await tester.pump();
    expect(find.byTooltip('Go'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(opened, ['https://codeberg.org/theoden8']);
    expect(searches, isEmpty);
  });

  testWidgets('the picker changes the search site and keeps the field',
      (tester) async {
    await pumpBar(tester);
    await tester.tap(magnifier());
    await tester.pump();
    await tester.tap(find.byTooltip('Choose search site'));
    await tester.pumpAndSettle();
    expect(find.text('DuckDuckGo'), findsOneWidget);
    await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Kagi'));
    await tester.pumpAndSettle();
    expect(hint(tester), 'Search with Kagi');
    await tester.enterText(find.byType(TextField), 'webview');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(searches, [('webview', 'kagi')]);
  });

  testWidgets('one search site needs no picker', (tester) async {
    await pumpBar(tester, sites: const [_ddg]);
    await tester.tap(magnifier());
    await tester.pump();
    expect(find.byTooltip('Choose search site'), findsNothing);
    expect(hint(tester), 'Search with DuckDuckGo');
  });

  testWidgets('with no search site the host is asked to offer one',
      (tester) async {
    await pumpBar(tester, sites: const []);
    await tester.tap(magnifier());
    await tester.pump();
    expect(hint(tester), 'Web search');
    await tester.enterText(find.byType(TextField), 'webview');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(searches, [('webview', null)]);
  });

  testWidgets('leaving the field ends search mode and shows the URL again',
      (tester) async {
    await pumpBar(tester);
    await tester.tap(magnifier());
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'half typed');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(shown(tester), 'https://github.com/theoden8');
    expect(hint(tester), 'Enter URL');
    expect(magnifier(), findsOneWidget);
  });

  testWidgets('without a search handler the bar is an address field',
      (tester) async {
    await pumpBar(tester, canSearch: false);
    expect(magnifier(), findsNothing);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'flutter');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(opened, ['https://flutter']);
  });

  testWidgets('a blank search does nothing', (tester) async {
    await pumpBar(tester);
    await tester.tap(magnifier());
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(searches, isEmpty);
    expect(opened, isEmpty);
  });
}
