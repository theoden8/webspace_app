import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/widgets/web_search_sheet.dart';

SearchSite site(String id, String name, String url) => SearchSite(
      siteId: id,
      name: name,
      initUrl: url,
      capability: WebSearchEngine.capabilityOf(initUrl: url),
    );

final gh = site('gh', 'GitHub', 'https://github.com/');
final blog = site('blog', 'Blog', 'https://blog.example/');
final ddg = site('ddg', 'DuckDuckGo', 'https://duckduckgo.com/');
final kagi = site('kagi', 'Kagi', 'https://kagi.com/');

void main() {
  /// Opens the sheet from a button, as the page menu does, and records what it
  /// returns.
  Future<List<WebSearchRequest?>> openSheet(
    WidgetTester tester, {
    required SearchSite identity,
    List<SearchSite> candidates = const [],
    List<String> declared = const [],
    String? declaredDefault,
    String? appDefault,
    bool canAddSites = true,
  }) async {
    final results = <WebSearchRequest?>[];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              results.add(await showModalBottomSheet<WebSearchRequest>(
                context: context,
                isScrollControlled: true,
                builder: (_) => WebSearchSheet(
                  identity: identity,
                  candidates: candidates,
                  declared: declared,
                  declaredDefault: declaredDefault,
                  appDefault: appDefault,
                  canAddSites: canAddSites,
                ),
              ));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  testWidgets('on GitHub it opens on GitHub with its own search (S1)',
      (tester) async {
    final results =
        await openSheet(tester, identity: gh, candidates: [gh, ddg, kagi]);
    expect(find.text('Search with GitHub'), findsOneWidget);
    await search(tester, '  flutter tabs  ');
    final r = results.single!;
    expect(r.query, 'flutter tabs');
    expect(r.scope, SearchScope.thisSite);
    expect(r.option!.site.siteId, 'gh');
    expect(r.option!.scoped, isFalse);
  });

  testWidgets('the web scope starts on the app default (S2)', (tester) async {
    final results = await openSheet(tester,
        identity: gh, candidates: [gh, ddg, kagi], appDefault: 'kagi');
    await tester.tap(find.text('The web'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget,
        reason: 'only the scope button names GitHub now');
    expect(find.text('Search with Kagi'), findsOneWidget);
    await search(tester, 'tabs');
    expect(results.single!.scope, SearchScope.web);
    expect(results.single!.option!.site.siteId, 'kagi');
  });

  testWidgets('a site without search is searched through an engine (S3)',
      (tester) async {
    final results =
        await openSheet(tester, identity: blog, candidates: [blog, ddg, kagi]);
    await tester.tap(find.text('Blog'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Kagi'));
    await tester.pumpAndSettle();
    await search(tester, 'webview');
    expect(results.single!.option!.site.siteId, 'kagi');
    expect(results.single!.option!.scoped, isTrue);
  });

  testWidgets('a declared list limits the chips (S11)', (tester) async {
    await openSheet(tester,
        identity: blog,
        candidates: [blog, ddg, kagi],
        declared: ['kagi'],
        declaredDefault: 'kagi');
    expect(find.widgetWithText(ChoiceChip, 'Kagi'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'DuckDuckGo'), findsNothing);
  });

  testWidgets('with no search sites, an engine can be added (S10)',
      (tester) async {
    final results = await openSheet(tester, identity: blog, candidates: [blog]);
    expect(find.text('None of your sites can run this search. Add one:'),
        findsOneWidget);
    await tester.enterText(find.byType(TextField), 'tabs');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();
    expect(results, isEmpty, reason: 'nothing picked yet');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Brave Search'));
    await tester.pumpAndSettle();
    expect(find.text('Search with Brave Search'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();
    expect(results.single!.option, isNull);
    expect(results.single!.add!.home, 'https://search.brave.com/');
  });

  testWidgets('inside an archive no engine is added (S15)', (tester) async {
    final results = await openSheet(tester,
        identity: blog, candidates: [blog], canAddSites: false);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.enterText(find.byType(TextField), 'tabs');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
  });

  testWidgets('a web engine on screen has no site scope (S5)', (tester) async {
    await openSheet(tester, identity: ddg, candidates: [ddg, kagi]);
    expect(find.byType(SegmentedButton<SearchScope>), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'DuckDuckGo'), findsOneWidget);
  });

  testWidgets('a blank query does nothing', (tester) async {
    final results =
        await openSheet(tester, identity: gh, candidates: [gh, ddg]);
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(find.byType(WebSearchSheet), findsOneWidget);
  });
}
