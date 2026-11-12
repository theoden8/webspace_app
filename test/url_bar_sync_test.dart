import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/keyboard_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'helpers/localized.dart';

Widget _host(Widget child) => localizedApp(Scaffold(body: child));

String _shown(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

Future<void> _submit(WidgetTester tester, {required String typed}) async {
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

      await _submit(tester, typed: 'site-b.example');

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

      await _submit(tester, typed: 'site-a.example/next');
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

  group('NAV-021 URL bar when the page under it changes', () {
    testWidgets('an edit ends with the page it began on (BUG-015)',
        (tester) async {
      PageFace page = (site: SiteId('site-a'), tab: TabId('t1'));
      var current = 'https://site-a.example/';
      late StateSetter rebuild;
      await tester.pumpWidget(_host(StatefulBuilder(builder: (context, set) {
        rebuild = set;
        return UrlBar(page: page, currentUrl: current, onUrlSubmitted: (_) {});
      })));

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'half-typ');
      rebuild(() {
        page = (site: SiteId('site-b'), tab: TabId('t1'));
        current = 'https://site-b.example/';
      });
      await tester.pump();

      expect(_shown(tester), 'https://site-b.example/');
      expect(tester.testTextInput.isVisible, isFalse);
    });
  });
}
