import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/tor_engine.dart' show kTorAppGlobalTag;
import 'package:webspace/services/tor_holders.dart';

void main() {
  const names = {'a1': 'Mail', 'b2': 'bank', 'c3': 'Forum'};

  test('nothing held is empty', () {
    final s = summarizeTorHolders(const [], names);
    expect(s.isEmpty, isTrue);
    expect(s.appWide, isFalse);
  });

  test('the app-wide tag is app traffic, not a site', () {
    final s = summarizeTorHolders({kTorAppGlobalTag}, names);
    expect(s.appWide, isTrue);
    expect(s.sites, isEmpty);
    expect(s.otherSites, 0);
  });

  test('sites are named and sorted without regard to case', () {
    final s = summarizeTorHolders({'c3', 'a1', 'b2'}, names);
    expect(s.sites, ['bank', 'Forum', 'Mail']);
  });

  test('a nested browser counts as the site that opened it, once', () {
    final s = summarizeTorHolders(
        {'a1', '${kTorNestedHolderPrefix}a1', '${kTorNestedHolderPrefix}b2'},
        names);
    expect(s.sites, ['bank', 'Mail']);
  });

  test('an interstitial is not a user of its own', () {
    final s = summarizeTorHolders(
        {'${kTorInterstitialHolderPrefix}12345', kTorAppGlobalTag}, names);
    expect(s.sites, isEmpty);
    expect(s.otherSites, 0);
    expect(s.appWide, isTrue);
  });

  test('a site with no name to show is counted, not named', () {
    // An archive-tier site is left out of the name map on purpose.
    final s = summarizeTorHolders({'a1', 'zz-archived'}, names);
    expect(s.sites, ['Mail']);
    expect(s.otherSites, 1);
  });
}
