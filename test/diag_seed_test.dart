import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/diag_seed.dart';

String encodeSeed(Object seed) => base64.encode(utf8.encode(jsonEncode(seed)));

void main() {
  test('parses sites and defaults currentIndex to 0', () {
    final seed = DiagSeed.parse(encodeSeed({
      'sites': [
        {'name': 'Dark', 'url': 'http://10.0.2.2:1234/dark.html'},
        {'name': 'White', 'url': 'http://10.0.2.2:1234/white.html'},
      ],
    }));
    expect(seed.sites, hasLength(2));
    expect(seed.sites[0].initUrl, 'http://10.0.2.2:1234/dark.html');
    expect(seed.sites[0].name, 'Dark');
    expect(seed.currentIndex, 0);
  });

  test('honors explicit currentIndex', () {
    final seed = DiagSeed.parse(encodeSeed({
      'sites': [
        {'name': 'A', 'url': 'http://h/a'},
        {'name': 'B', 'url': 'http://h/b'},
      ],
      'currentIndex': 1,
    }));
    expect(seed.currentIndex, 1);
  });

  test('generates fresh siteIds per parse so runs cannot share keyed state',
      () {
    final payload = encodeSeed({
      'sites': [
        {'name': 'A', 'url': 'http://h/a'},
      ],
    });
    final first = DiagSeed.parse(payload).sites.single.siteId;
    final second = DiagSeed.parse(payload).sites.single.siteId;
    expect(first, isNot(second));
  });

  test('rejects an empty site list', () {
    expect(() => DiagSeed.parse(encodeSeed({'sites': []})),
        throwsFormatException);
  });

  test('rejects out-of-range currentIndex', () {
    expect(
        () => DiagSeed.parse(encodeSeed({
              'sites': [
                {'name': 'A', 'url': 'http://h/a'},
              ],
              'currentIndex': 3,
            })),
        throwsRangeError);
  });

  test('rejects non-base64 garbage', () {
    expect(() => DiagSeed.parse('not base64!!'), throwsFormatException);
  });
}
