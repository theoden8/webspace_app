import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/widgets/external_url_prompt.dart';

import 'helpers/fake_webview_controller.dart';
import 'helpers/localized.dart';

void main() {
  setUp(() {
    ClearUrlService.instance.loadRulesFromJson({
      'providers': {
        'google': {
          'urlPattern': r'google\.com',
          'completeProvider': false,
          'rules': [r'^utm_campaign$'],
          'rawRules': [],
          'exceptions': [],
          'redirections': [],
        },
      },
    });
  });

  /// The prompt for [url], opened from a page whose webview is [view].
  Future<void> prompt(
    WidgetTester tester, {
    required String url,
    required FakeWebViewController view,
  }) async {
    await pumpLocalized(
      tester,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => confirmAndLaunchExternalUrl(
            context,
            info: ExternalUrlParser.parse(url)!,
            loadInWebView: view,
          ),
          child: const Text('go'),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      "EXT-005: 'Open in browser' loads the cleaned fallback in this webview, "
      'and the choice silences the next fire', (tester) async {
    const fallback =
        'https://www.google.com/maps?entry=ml&utm_campaign=ml-ardi-wv';
    final url = 'intent://maps.example/#Intent;scheme=geo;'
        'package=com.example.maps;'
        'S.browser_fallback_url=${Uri.encodeComponent(fallback)};end';
    final view = FakeWebViewController();
    await prompt(tester, url: url, view: view);

    expect(find.text('Open in browser'), findsOneWidget);
    await tester.tap(find.text('Open in browser'));
    await tester.pumpAndSettle();

    expect(view.calls, ['loadUrl https://www.google.com/maps?entry=ml'],
        reason: 'we are the browser: the site loads it with its own settings '
            '(EXT-006 strips the tracking parameter first)');
    expect(
        ExternalUrlSuppressor.isSuppressedInfo(ExternalUrlParser.parse(url)!),
        isTrue);
  });

  testWidgets('EXT-005: a fallback that is no web page is never offered',
      (tester) async {
    final url = 'intent://x/#Intent;scheme=geo;package=com.example.other;'
        'S.browser_fallback_url=${Uri.encodeComponent('file:///etc/hosts')};end';
    final view = FakeWebViewController();
    await prompt(tester, url: url, view: view);

    expect(find.text('Open in browser'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(view.calls, isEmpty);
  });
}
