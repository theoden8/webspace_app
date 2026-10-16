import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/tor_holders.dart';

Set<TorHolder> _sites(List<String> ids) => {
  for (final id in ids) TorSiteHolder(SiteId(id)),
};

void main() {
  final sites = <SiteId, TorSiteLabel>{
    SiteId('a1'): (name: 'Mail', exitNodes: '{de}'),
    SiteId('b2'): (name: 'bank', exitNodes: null),
    SiteId('c3'): (name: 'Forum', exitNodes: '{nl}'),
  };
  List<String> names(TorHolderSummary s) => [for (final x in s.sites) x.name];

  test('nothing held is empty', () {
    final s = summarizeTorHolders(const [], sites: sites);
    expect(s.isEmpty, isTrue);
    expect(s.appWide, isFalse);
  });

  test('the app-wide tag is app traffic, not a site', () {
    final s = summarizeTorHolders({const TorAppWideHolder()}, sites: sites);
    expect(s.appWide, isTrue);
    expect(s.sites, isEmpty);
    expect(s.otherSites, 0);
  });

  test('sites are named and sorted without regard to case', () {
    final s = summarizeTorHolders(_sites(['c3', 'a1', 'b2']), sites: sites);
    expect(names(s), ['bank', 'Forum', 'Mail']);
  });

  test('each site keeps its own exit country; they need not agree', () {
    // The holders are every site set to Tor, loaded or not; only loaded
    // sites must share one pin (TOR-014).
    final s = summarizeTorHolders(_sites(['c3', 'a1', 'b2']), sites: sites);
    expect([for (final x in s.sites) x.exitNodes], [null, '{nl}', '{de}']);
  });

  test('a nested browser counts as the site that opened it, once', () {
    final s = summarizeTorHolders({
      TorSiteHolder(SiteId('a1')),
      TorNestedHolder(SiteId('a1')),
      TorNestedHolder(SiteId('b2')),
    }, sites: sites);
    expect(names(s), ['bank', 'Mail']);
  });

  test('an interstitial is not a user of its own', () {
    final s = summarizeTorHolders({
      TorInterstitialHolder(Object()),
      const TorAppWideHolder(),
    }, sites: sites);
    expect(s.sites, isEmpty);
    expect(s.otherSites, 0);
    expect(s.appWide, isTrue);
  });

  test('a site with no name to show is counted, not named', () {
    // An archive-tier site is left out of the name map on purpose.
    final s =
        summarizeTorHolders(_sites(['a1', 'zz-archived']), sites: sites);
    expect(names(s), ['Mail']);
    expect(s.otherSites, 1);
  });

  test('holders of different kinds for one site are distinct', () {
    expect(TorSiteHolder(SiteId('a1')), isNot(TorNestedHolder(SiteId('a1'))));
  });
}
