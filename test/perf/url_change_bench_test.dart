// Times what the app does when the page on screen changes its URL without a
// load (`history.replaceState`), which many pages do on every keystroke.
//
//   WS_PERF=1 fvm flutter test test/perf/url_change_bench_test.dart
//
// Dart work on the UI isolate, which on Android is the thread the webview
// takes its input on; the faked platform answers at once, so a device adds
// its keystore and preferences writes on top.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

import '../helpers/real_app.dart';
import 'perf_samples.dart';

const _events = 40;
const _siteCount = 20;

List<WebViewModel> _sites() => [
      for (var i = 0; i < _siteCount; i++)
        WebViewModel(initUrl: 'https://site$i.example.test', name: 'Site $i')
          ..cookies = [
            for (var c = 0; c < 15; c++)
              inapp.Cookie(
                name: 'c$c',
                value: 'v' * 40,
                domain: 'site$i.example.test',
                isSecure: c.isEven,
              ),
          ],
    ];

void main() {
  final skip = Platform.environment['WS_PERF'] == null;

  // New URLs first: the same-URL run then follows identical work on any
  // checkout, so state the first test leaves behind cannot favour one side.
  for (final changing in [true, false]) {
    testWidgets(
        '$_events history updates, ${changing ? 'a new URL each' : 'same URL'}',
        (tester) async {
      await pumpRealApp(tester, sites: _sites());
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'Site 0');
      await attachWebViews(tester);

      Future<double> burst(String Function(int i) url) async {
        final sw = Stopwatch()..start();
        for (var i = 0; i < _events; i++) {
          await pageHistoryChanged(tester, url: url(i));
          await tester.pump();
        }
        await settleRealApp(tester);
        return elapsedMs(sw);
      }

      String url(int i) => changing
          ? 'https://site0.example.test/search?q=${'a' * (i + 1)}'
          : 'https://site0.example.test/search';
      // Warm the whole save path in each test, so neither test's numbers
      // depend on which ran first in the process.
      for (var w = 0; w < 10; w++) {
        await burst((i) => 'https://site0.example.test/warm?w=$w&i=$i');
      }
      await burst(url);
      // settleRealApp's fixed pumps cost the same in every burst.
      final settleOnly = await () async {
        final sw = Stopwatch()..start();
        await settleRealApp(tester);
        return elapsedMs(sw);
      }();
      reportSamples('${changing ? 'new URL each' : 'same URL'}: ms per update', samples: [
        for (var r = 0; r < perfRuns; r++) ((await burst(url)) - settleOnly) / _events,
      ]);
    }, skip: skip);
  }
}
