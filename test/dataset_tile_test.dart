import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/widgets/datasets.dart';
import 'package:webspace/widgets/dataset_tile.dart';

import 'helpers/localized.dart';

class _Dataset extends ChangeNotifier implements DownloadableDataset {
  @override
  bool ready = false;
  @override
  DateTime? lastUpdated;
  String? line = 'Not downloaded';
  Completer<String>? running;
  int downloads = 0;

  @override
  String? status(AppLocalizations loc) => line;

  @override
  Future<String> download(AppLocalizations loc) {
    downloads++;
    running = Completer();
    return running!.future;
  }
}

class _ClearableDataset extends _Dataset implements ClearableDataset {
  int clears = 0;

  @override
  Future<String?> clear(AppLocalizations loc) async {
    clears++;
    ready = false;
    notifyListeners();
    return null;
  }
}

Widget _host(
  DownloadableDataset dataset, {
  Widget Function(DownloadableDataset dataset,
      {required VoidCallback? download})? below,
}) => localizedApp(
  Scaffold(
    body: ListView(
      children: [
        DatasetTile<DownloadableDataset>(
          create: () => dataset,
          icon: Icons.public,
          title: 'Polygons',
          hint: 'What the polygons are for.',
          below: below,
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets('names what is on disk and when it was fetched', (tester) async {
    final dataset = _Dataset()
      ..ready = true
      ..line = '2 zones'
      ..lastUpdated = DateTime(2026, 8, 20, 10, 44, 3);
    await tester.pumpWidget(_host(dataset));

    expect(find.text('2 zones'), findsOneWidget);
    expect(find.text('Updated: 2026-08-20 10:44:03'), findsOneWidget);
    expect(find.byTooltip('Refresh dataset'), findsOneWidget);
  });

  testWidgets('a download in flight shows a spinner, then its message', (
    tester,
  ) async {
    final dataset = _Dataset();
    final handed = <VoidCallback?>[];
    await tester.pumpWidget(
      _host(
        dataset,
        below: (_, {required download}) {
          handed.add(download);
          return const SizedBox.shrink();
        },
      ),
    );

    await tester.tap(find.byTooltip('Download dataset'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      handed.last,
      isNull,
      reason: 'controls under the row cannot start a second download',
    );

    await tester.tap(find.byType(ListTile));
    expect(dataset.downloads, 1);

    dataset.running!.complete('Loaded');
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Loaded'), findsOneWidget);
    expect(handed.last, isNotNull);
  });

  testWidgets('only a clearable dataset with data offers to clear it', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_Dataset()..ready = true));
    expect(find.byTooltip('Clear dataset'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(_ClearableDataset()));
    expect(find.byTooltip('Clear dataset'), findsNothing);
    expect(find.byTooltip('Download dataset'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    final clearable = _ClearableDataset()..ready = true;
    await tester.pumpWidget(_host(clearable));
    await tester.tap(find.byTooltip('Clear dataset'));
    await tester.pumpAndSettle();
    expect(clearable.clears, 1);
    expect(find.byTooltip('Download dataset'), findsOneWidget);
  });

  testWidgets('the Firefox row keeps its auto-update choice in prefs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({AppPref.firefoxUaAutoRefresh.key: true});
    final firefox = FirefoxVersionDataset();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(firefox.autoRefresh, isTrue);

    await tester.runAsync(() => firefox.setAutoRefresh(on: false));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.firefoxUaAutoRefresh.key), isFalse);
    firefox.dispose();
  });

  // A title, a hint button, a date, a switch under it and a button beside it:
  // narrow screens and large text scales are where a Row runs out of width.
  testWidgets('lays out without overflow across widths and text scales', (
    tester,
  ) async {
    final complaints = <String>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) =>
        complaints.add('${details.exception}'.split('\n').first);
    addTearDown(() => FlutterError.onError = previousOnError);

    for (final width in <double>[200, 240, 280, 320, 360, 412, 480, 800]) {
      for (final scale in <double>[1.0, 1.3, 1.6, 2.0, 2.5]) {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = Size(width, 800);
        addTearDown(tester.view.reset);
        final dataset = _Dataset()
          ..ready = true
          ..line = 'Firefox 152'
          ..lastUpdated = DateTime(2026, 8, 20, 10, 44, 3);
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: _host(
              dataset,
              below: (_, {required download}) => SwitchListTile(
                title: const Text('Check weekly'),
                value: true,
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(complaints, isEmpty, reason: 'width $width, text scale $scale');
      }
    }
  });
}
