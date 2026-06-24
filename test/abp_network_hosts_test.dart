import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/abp_network_hosts.dart';

// Mirror the JS interceptor's URL tokenizer (urlMaybeGeneric in
// webview.dart): split on every non-[a-z0-9] char, keep runs >= 3.
// Used to assert the end-to-end contract: a rule's stored token is
// present among the tokens of any URL the rule matches.
Set<String> _urlTokens(String url) {
  final out = <String>{};
  final s = url.toLowerCase();
  var start = -1;
  for (var i = 0; i <= s.length; i++) {
    final c = i < s.length ? s.codeUnitAt(i) : 0;
    final alnum = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a);
    if (alnum) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      if (i - start >= 3) out.add(s.substring(start, i));
      start = -1;
    }
  }
  return out;
}

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

  group('parseAbpNetworkPrefilter tokens', () {
    test('extracts one longest literal token per hostless rule', () {
      final r = parseAbpNetworkPrefilter('''
/ads/banner-
example.com/tracker.gif
/pagead/conversion
''');
      // longest [a-z0-9] run per rule: banner (>ads), tracker (>example
      // is a tie won by tracker only if first; here example precedes so
      // assert the unambiguous ones), conversion (>pagead).
      expect(r.tokens, contains('banner'));
      expect(r.tokens, contains('conversion'));
      expect(r.tokens.length, 3, reason: 'one token per rule');
      expect(r.hasUntokenizable, isFalse);
    });

    test('host-anchored rules contribute a host, not a token', () {
      final r = parseAbpNetworkPrefilter('||ads.example.com^\$script');
      expect(r.hosts, {'ads.example.com'});
      expect(r.tokens, isEmpty);
    });

    test('||-anchored rules with an unclean host fall through to a token', () {
      // Wildcard / illegal char in the host portion yields no clean host;
      // it must still produce a trigger (token) rather than be dropped.
      final r = parseAbpNetworkPrefilter('||sub.*.example^\n||*adservice*^');
      expect(r.hosts, isEmpty);
      expect(r.tokens, contains('example'));
      expect(r.tokens, contains('adservice'));
      // Contract: a matching URL carries the token.
      expect(_urlTokens('https://sub.cdn.example/x'), contains('example'));
    });

    test('regex rules set hasUntokenizable and yield no token', () {
      final r = parseAbpNetworkPrefilter(r'/[a-z]{8}\.com\/ad/');
      expect(r.tokens, isEmpty);
      expect(r.hasUntokenizable, isTrue);
    });

    test('rules whose only runs are < 3 chars set hasUntokenizable', () {
      final r = parseAbpNetworkPrefilter('/ad/');
      expect(r.tokens, isEmpty);
      expect(r.hasUntokenizable, isTrue);
    });

    test('options are stripped before tokenizing', () {
      final r = parseAbpNetworkPrefilter('/analytics.js\$script,third-party');
      expect(r.tokens, contains('analytics'));
      // "script"/"party" come from options and must NOT be tokens.
      expect(r.tokens, isNot(contains('script')));
    });

    test('no false negative: the stored token is present in a matching URL',
        () {
      // The correctness contract. For each hostless rule, the token we
      // bloom must appear among the tokens of a URL the rule matches, so
      // the JS prefilter trips and Dart adjudicates.
      final cases = <String, String>{
        '/ads/banner-': 'https://news.example.com/ads/banner-300x250.png',
        '|http://x.com/tracker.gif': 'http://x.com/tracker.gif?u=1',
        '/pagead/conversion': 'https://g.example/pagead/conversion/123',
        'doubleclicktrack': 'https://cdn.example/js/doubleclicktrack.min.js',
      };
      cases.forEach((rule, url) {
        final r = parseAbpNetworkPrefilter(rule);
        expect(r.tokens, isNotEmpty, reason: 'rule "$rule" produced no token');
        final urlTokens = _urlTokens(url);
        for (final t in r.tokens) {
          expect(urlTokens, contains(t),
              reason: 'token "$t" from "$rule" missing in URL tokens of $url');
        }
      });
    });
  });
}
