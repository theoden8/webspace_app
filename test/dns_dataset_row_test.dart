import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/app_privacy.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/widgets/level_slider.dart';

import 'helpers/localized.dart';

/// App Settings' DNS blocklist row, over the service as it stands.
Widget _row() => localizedApp(
      const Scaffold(body: SingleChildScrollView(child: DnsBlocklistTile())),
    );

void main() {
  tearDown(DnsBlockService.instance.resetForTest);

  testWidgets(
      'DNS-007: the row names the level on disk, its domain count and when it '
      'was fetched', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'dns_block_last_updated': '2026-02-17T14:30:00.000'});
    DnsBlockService.instance.loadDomainsFromString(
      [for (var i = 0; i < 1500; i++) 'tracker$i.example'].join('\n'),
      level: 3,
    );

    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    expect(find.text('Pro - 1.5K domains'), findsOneWidget);
    expect(find.text('Updated: 2026-02-17 14:30:00'), findsOneWidget);
  });

  testWidgets('DNS-007: with no list downloaded the row says so',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    DnsBlockService.instance.resetForTest();

    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    expect(find.text('Not configured'), findsOneWidget);
    expect(find.textContaining('Updated:'), findsNothing);
  });

  group('DNS-006: the level slider', () {
    LevelSlider slider(WidgetTester tester) =>
        tester.widget<LevelSlider>(find.byType(LevelSlider));

    Future<void> withPro(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      DnsBlockService.instance.loadDomainsFromString('tracker.example', level: 3);
      await tester.pumpWidget(_row());
      await tester.pumpAndSettle();
    }

    testWidgets('opens at the downloaded level, every level named',
        (tester) async {
      await withPro(tester);
      expect(slider(tester).value, 3);
      for (final name in ['Off', 'Light', 'Normal', 'Pro', 'Pro++', 'Ultimate']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.byIcon(Icons.sync), findsOneWidget);
    });

    testWidgets('a move downloads nothing and marks the button as a new '
        'level to fetch', (tester) async {
      await withPro(tester);
      slider(tester).onChanged!(5);
      await tester.pumpAndSettle();
      expect(slider(tester).value, 5);
      expect(DnsBlockService.instance.level, 3, reason: 'nothing fetched');
      expect(find.text('Pro - 1 domains'), findsOneWidget);
      expect(find.byIcon(Icons.sync), findsNothing);
      expect(find.byIcon(Icons.download), findsOneWidget);
    });

    testWidgets('is disabled while a download runs', (tester) async {
      await withPro(tester);
      final store = _HeldStore();
      DnsBlockService.instance.store = store;
      slider(tester).onChanged!(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.download));
      await tester.pump();
      await tester.pump();
      expect(slider(tester).onChanged, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      store.release();
      await tester.pumpAndSettle();
      expect(slider(tester).onChanged, isNotNull);
      expect(slider(tester).value, 0);
    });
  });
}

/// A store whose deletes wait until [release], so a clear stays in flight.
class _HeldStore extends MemoryFileStore {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<void> delete(String name) async {
    await _gate.future;
    return super.delete(name);
  }
}
