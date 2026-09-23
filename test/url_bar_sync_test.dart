import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/url_bar.dart';

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

String _shown(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

Future<void> _submit(WidgetTester tester, String typed) async {
  await tester.tap(find.byType(TextField));
  await tester.pump();
  await tester.enterText(find.byType(TextField), typed);
  await tester.testTextInput.receiveAction(TextInputAction.go);
  await tester.pump();
}

void main() {
  group('NAV-007 URL bar after a submit', () {
    testWidgets(
        'a submit that opens elsewhere shows the site URL again once it returns',
        (tester) async {
      final nestedClosed = Completer<void>();
      await tester.pumpWidget(_host(UrlBar(
        currentUrl: 'https://site-a.example/page',
        onUrlSubmitted: (_) => nestedClosed.future,
      )));

      await _submit(tester, 'site-b.example');

      nestedClosed.complete();
      await tester.pump();

      expect(_shown(tester), 'https://site-a.example/page');
    });

    testWidgets('a submit that navigates this webview shows the new URL',
        (tester) async {
      var current = 'https://site-a.example/';
      late StateSetter rebuild;
      await tester.pumpWidget(_host(StatefulBuilder(builder: (context, set) {
        rebuild = set;
        return UrlBar(
          currentUrl: current,
          onUrlSubmitted: (url) async {
            await Future<void>.delayed(Duration.zero);
            rebuild(() => current = url);
          },
        );
      })));

      await _submit(tester, 'site-a.example/next');
      await tester.pumpAndSettle();

      expect(_shown(tester), 'https://site-a.example/next');
    });

    testWidgets('a navigation while the user is editing keeps their text',
        (tester) async {
      var current = 'https://site-a.example/';
      late StateSetter rebuild;
      await tester.pumpWidget(_host(StatefulBuilder(builder: (context, set) {
        rebuild = set;
        return UrlBar(currentUrl: current, onUrlSubmitted: (_) {});
      })));

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'half-typ');
      rebuild(() => current = 'https://site-a.example/elsewhere');
      await tester.pump();

      expect(_shown(tester), 'half-typ');
    });
  });
}
