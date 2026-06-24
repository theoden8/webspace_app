import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/abp_network_hosts.dart';

void main() {
  group('extractAbpNetworkBlockHosts', () {
    test('extracts plain ||host^ block rules', () {
      final hosts = extractAbpNetworkBlockHosts('''
||doubleclick.net^
||googlesyndication.com^
||ads.example.com^
''');
      expect(hosts, {
        'doubleclick.net',
        'googlesyndication.com',
        'ads.example.com',
      });
    });

    test('keeps the bare host from option-laden and path rules', () {
      // The prefilter is permissive: blockCheck applies the options
      // authoritatively on the round-trip, so we still want the host.
      final hosts = extractAbpNetworkBlockHosts('''
||tracker.example^\$third-party
||metrics.example.com^\$script,domain=foo.com
||cdn.example.org/ads/banner.js
||example.net:8080^
''');
      expect(hosts, {
        'tracker.example',
        'metrics.example.com',
        'cdn.example.org',
        'example.net',
      });
    });

    test('skips exceptions, cosmetics, comments, and hostless rules', () {
      final hosts = extractAbpNetworkBlockHosts('''
! a comment
[Adblock Plus 2.0]
@@||cdn.googlesyndication.com^
##.advert
linkedin.com##.feed-shared-update-v2--ad
example.com,test.com##.cross-site-ad
/banner/ads/*
|http://example.com/ad
||*.wildcard.example^
''');
      expect(hosts, isEmpty);
    });

    test('does not treat a substring class rule host as a block host', () {
      // `host##sel` cosmetic rules must never contribute a network host.
      final hosts = extractAbpNetworkBlockHosts('cnn.com##div[data-zone-id="ad"]');
      expect(hosts, isEmpty);
    });

    test('lowercases and dedups', () {
      final hosts = extractAbpNetworkBlockHosts('||Ads.Example.COM^\n||ads.example.com^');
      expect(hosts, {'ads.example.com'});
    });
  });
}
