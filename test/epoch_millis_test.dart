import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/utils/epoch_millis.dart';

void main() {
  test('a stored time a DateTime cannot hold reads as absent', () {
    expect(timeAtEpochMillis(8640000000000000), isNotNull);
    expect(timeAtEpochMillis(8640000000000001), isNull);
    expect(timeAtEpochMillis(-8640000000000001), isNull);
    expect(timeAtEpochMillis('1'), isNull);
    expect(timeAtEpochMillis(0, isUtc: true)!.isUtc, isTrue);
  });

  test('a tab whose stored time is out of range keeps its other fields', () {
    final tab = SiteTab.fromJson({
      'id': 'main',
      'url': 'https://example.com/',
      'createdAt': 9000000000000000,
    });
    expect(tab, isNotNull);
    expect(tab!.url, 'https://example.com/');
  });
}
