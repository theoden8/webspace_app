import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/runtime/arb_messages.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/widgets/dataset_tile.dart';
import 'package:webspace/widgets/datasets.dart';

import 'helpers/localized.dart';

/// App Settings' DNS blocklist row, over the service as it stands.
Widget _row() => localizedApp(
      Scaffold(
        body: ListView(
          children: [
            DatasetTile<DnsBlocklistDataset>(
              create: DnsBlocklistDataset.new,
              icon: Icons.dns,
              title: const Localized.verbatim('DNS Blocklist'),
              hint: const Localized.verbatim('What it blocks.'),
            ),
          ],
        ),
      ),
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
}
