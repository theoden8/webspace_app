import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/tor_holders.dart';

Set<TorHolder> _sites(List<String> ids) => {
  for (final id in ids) TorSiteHolder(id),
};

void main() {
  const names = {'a1': 'Mail', 'b2': 'bank', 'c3': 'Forum'};

  test('nothing held is empty', () {
    final s = summarizeTorHolders(const [], siteNames: names);
    expect(s.isEmpty, isTrue);
    expect(s.appWide, isFalse);
  });

  test('the app-wide tag is app traffic, not a site', () {
    final s = summarizeTorHolders({const TorAppWideHolder()}, siteNames: names);
    expect(s.appWide, isTrue);
    expect(s.sites, isEmpty);
    expect(s.otherSites, 0);
  });

  test('sites are named and sorted without regard to case', () {
    final s = summarizeTorHolders(_sites(['c3', 'a1', 'b2']), siteNames: names);
    expect(s.sites, ['bank', 'Forum', 'Mail']);
  });

  test('a nested browser counts as the site that opened it, once', () {
    final s = summarizeTorHolders({
      const TorSiteHolder('a1'),
      const TorNestedHolder('a1'),
      const TorNestedHolder('b2'),
    }, siteNames: names);
    expect(s.sites, ['bank', 'Mail']);
  });

  test('an interstitial is not a user of its own', () {
    final s = summarizeTorHolders({
      TorInterstitialHolder(Object()),
      const TorAppWideHolder(),
    }, siteNames: names);
    expect(s.sites, isEmpty);
    expect(s.otherSites, 0);
    expect(s.appWide, isTrue);
  });

  test('a site with no name to show is counted, not named', () {
    // An archive-tier site is left out of the name map on purpose.
    final s =
        summarizeTorHolders(_sites(['a1', 'zz-archived']), siteNames: names);
    expect(s.sites, ['Mail']);
    expect(s.otherSites, 1);
  });

  test('holders of different kinds for one site are distinct', () {
    expect(const TorSiteHolder('a1'), isNot(const TorNestedHolder('a1')));
  });
}
