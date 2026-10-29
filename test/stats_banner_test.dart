import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/widgets/stats_banner.dart';

import 'helpers/localized.dart';

void main() {
  final site = SiteId('banner-site');
  final dns = DnsBlockService.instance;

  setUp(() {
    dns.resetForTest();
    dns.loadDomainsFromString('beacon.example\nads.example\n');
  });
  tearDown(dns.resetForTest);

  Future<AppLocalizations> pumpBanner(WidgetTester tester) async {
    await pumpLocalized(tester,
        home: Scaffold(body: StatsBanner(siteId: site, dnsBlockEnabled: true)));
    return AppLocalizations.of(tester.element(find.byType(StatsBanner)));
  }

  testWidgets('shows what the site blocked and allowed (DNS-013)',
      (tester) async {
    dns.statsForSite(site)
      ..record('beacon.example', wasBlocked: true, source: BlockSource.dns)
      ..record('www.example', wasBlocked: false, count: 30);
    final loc = await pumpBanner(tester);
    expect(find.text(loc.statsBannerBlocked(1)), findsOneWidget);
    expect(find.text(loc.statsBannerAllowed(30)), findsOneWidget);
  });

  testWidgets('a tap lists each blocker and the hosts blocked most (DNS-013)',
      (tester) async {
    dns.statsForSite(site)
      ..record('beacon.example',
          wasBlocked: true, source: BlockSource.dns, count: 12)
      ..record('ads.example',
          wasBlocked: true, source: BlockSource.abp, count: 3)
      ..record('www.example', wasBlocked: false, count: 30);
    final loc = await pumpBanner(tester);
    expect(find.text('beacon.example'), findsNothing);

    await tester.tap(find.byType(StatsBanner));
    await tester.pumpAndSettle();

    Finder row(String label) => find.ancestor(
        of: find.text(label), matching: find.byType(Row)).first;
    String countIn(String label) => tester
        .widgetList<Text>(find.descendant(of: row(label), matching: find.byType(Text)))
        .last
        .data!;
    expect(countIn(loc.blockStatsCategoryDns), '12');
    expect(countIn(loc.blockStatsCategoryFilterList), '3');
    expect(find.text(loc.blockStatsDetailItems), findsOneWidget);
    expect(countIn('beacon.example'), '12');
    expect(countIn('ads.example'), '3');
    expect(
      tester.getTopLeft(find.text('beacon.example')).dy,
      lessThan(tester.getTopLeft(find.text('ads.example')).dy),
      reason: 'the host blocked most comes first',
    );
  });

  testWidgets('hidden until the site has recorded a request (DNS-013)',
      (tester) async {
    await pumpBanner(tester);
    expect(find.byIcon(Icons.shield), findsNothing);
  });

  testWidgets('hidden while no list is loaded (DNS-013)', (tester) async {
    dns.resetForTest();
    dns.statsForSite(site).record('www.example', wasBlocked: false);
    await pumpBanner(tester);
    expect(find.byIcon(Icons.shield), findsNothing);
  });
}
