import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_list.dart';

void main() {
  test('a line names its domain in a domain list or a hosts file', () {
    expect(listedDomain('example.com'), 'example.com');
    expect(listedDomain('  Example.COM  '), 'example.com');
    expect(listedDomain('0.0.0.0 example.com'), 'example.com');
    expect(listedDomain('0.0.0.0\texample.com # why'), 'example.com');
    expect(listedDomain('# Title: a list'), isNull);
    expect(listedDomain('   '), isNull);
  });

  test('a list reads line by line, comments and blanks skipped', () {
    expect(listedDomains('# head\na.example\n\n0.0.0.0 b.example\r\n').toList(),
        ['a.example', 'b.example']);
  });
}
