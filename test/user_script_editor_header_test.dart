import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/settings/user_script.dart';

import 'helpers/localized.dart';

/// The editor's reading of a script's header: what it names, what WebSpace
/// does not provide, the injection time it sets, and the name it gives a
/// new script.
void main() {
  late AppLocalizations en;
  setUpAll(() async => en = await AppLocalizations.delegate.load(const Locale('en')));

  String block(List<String> lines) =>
      ['// ==UserScript==', ...lines, '// ==/UserScript=='].join('\n');

  Future<void> open(WidgetTester tester, {UserScriptConfig? script}) =>
      pumpLocalized(tester,
          home: UserScriptEditScreen(script: script, proxy: OutboundProxy.app));

  Finder source() => find.byType(TextField).last;
  Finder name() => find.byType(TextField).first;
  String nameText(WidgetTester tester) =>
      tester.widget<TextField>(name()).controller!.text;

  testWidgets('US-012: the summary lists pages, exclusions and what is not provided',
      (tester) async {
    await open(tester,
        script: UserScriptConfig(
            name: 'Shorts',
            source: '${block([
              '// @match https://*.youtube.com/*',
              '// @exclude-match https://*.youtube.com/live*',
              '// @grant GM_xmlhttpRequest',
              '// @require https://code.jquery.com/jquery.min.js',
            ])}\nrun();'));
    expect(find.text(en.userScriptHeaderTitle.toString()), findsOneWidget);
    expect(find.text(en.userScriptHeaderRunsOn('https://*.youtube.com/*').toString()),
        findsOneWidget);
    expect(
        find.text(en.userScriptHeaderExcludes('https://*.youtube.com/live*').toString()),
        findsOneWidget);
    expect(
        find.text(en
            .userScriptHeaderNotProvided('@grant GM_xmlhttpRequest · '
                '@require https://code.jquery.com/jquery.min.js')
            .toString()),
        findsOneWidget);
  });

  testWidgets('US-012: @grant none lists nothing as not provided', (tester) async {
    await open(tester,
        script: UserScriptConfig(name: 'n', source: block(['// @grant none'])));
    expect(find.text(en.userScriptHeaderEveryPage.toString()), findsOneWidget);
    expect(find.textContaining('WebSpace does not provide'), findsNothing);
  });

  testWidgets('US-008: a source with no header shows no summary', (tester) async {
    await open(tester, script: UserScriptConfig(name: 'p', source: 'run();'));
    expect(find.text(en.userScriptHeaderTitle.toString()), findsNothing);
  });

  testWidgets('US-008: an unclosed header and an invalid pattern are reported',
      (tester) async {
    await open(tester,
        script: UserScriptConfig(
            name: 'u', source: '// ==UserScript==\n// @match https://a.example/*'));
    expect(find.text(en.userScriptHeaderUnclosed.toString()), findsOneWidget);

    await tester.enterText(source(), block(['// @match https://example.com']));
    await tester.pump();
    expect(find.text(en.userScriptHeaderNoPage.toString()), findsOneWidget);
    expect(
        find.text(en
            .userScriptHeaderInvalidPattern('@match https://example.com')
            .toString()),
        findsOneWidget);
  });

  testWidgets('US-010: @run-at locks the injection time and says the header sets it',
      (tester) async {
    await open(tester,
        script: UserScriptConfig(
            name: 'r', source: block(['// @run-at document-start'])));
    final picker = find.byType(DropdownButtonFormField<UserScriptInjectionTime>);
    expect(find.descendant(of: picker, matching: find.text('Document start')),
        findsOneWidget);
    expect(find.text(en.userScriptHeaderSetsRunAt.toString()), findsOneWidget);
    expect(
        tester
            .widget<DropdownButton<UserScriptInjectionTime>>(find.descendant(
                of: picker,
                matching: find.byType(DropdownButton<UserScriptInjectionTime>)))
            .onChanged,
        isNull,
        reason: 'the header decides it, not the picker');

    await tester.enterText(source(), 'run();');
    await tester.pump();
    expect(find.descendant(of: picker, matching: find.text('Document end')),
        findsOneWidget, reason: 'without the header the stored time returns');
    expect(find.text(en.userScriptHeaderSetsRunAt.toString()), findsNothing);
  });

  testWidgets('US-010: an unknown @run-at is reported and leaves the picker free',
      (tester) async {
    await open(tester,
        script: UserScriptConfig(
            name: 'r', source: block(['// @run-at context-menu'])));
    expect(find.text(en.userScriptHeaderUnknownRunAt('context-menu').toString()),
        findsOneWidget);
    expect(find.text(en.userScriptHeaderSetsRunAt.toString()), findsNothing);
  });

  testWidgets('US-011: a new script takes its pasted header\'s name', (tester) async {
    await open(tester);
    await tester.enterText(source(), block(['// @name Hide shorts']));
    await tester.pump();
    expect(nameText(tester), 'Hide shorts');
  });

  testWidgets('US-011: a name the user typed is kept', (tester) async {
    await open(tester);
    await tester.enterText(name(), 'Mine');
    await tester.enterText(source(), block(['// @name Hide shorts']));
    await tester.pump();
    expect(nameText(tester), 'Mine');
  });

  testWidgets('US-011: an existing script keeps its name when its header changes',
      (tester) async {
    await open(tester, script: UserScriptConfig(name: 'Old', source: 'run();'));
    await tester.enterText(name(), '');
    await tester.enterText(source(), block(['// @name New']));
    await tester.pump();
    expect(nameText(tester), '');
  });
}
