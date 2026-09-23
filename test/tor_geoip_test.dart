// TOR-014 GeoIP: the table a country pin needs, fetched on the device
// (LICENSE-002 keeps it out of the release artifact).
//
// Every table here is synthetic. The real one is IPFire data under
// CC BY-SA 4.0, and copyleft data is not committed to this repo either.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/tor_geoip.dart';
import 'package:webspace/services/tor_geoip_io.dart';
import 'package:webspace/settings/proxy.dart';

String _table({
  String licence = kTorGeoIpLicence,
  int rows = kTorGeoIpMinRows,
  String eol = '\n',
}) {
  final b = StringBuffer()
    ..write('# Location Database Export$eol')
    ..write('#$eol')
    ..write('# License:   $licence$eol')
    ..write('#$eol');
  for (var i = 0; i < rows; i++) {
    b.write('${i * 10},${i * 10 + 9},${i.isEven ? 'BR' : '??'}$eol');
  }
  return b.toString();
}

class _Factory implements OutboundHttpFactory {
  _Factory(this.handler);
  final Future<http.Response> Function(http.Request) handler;
  final seen = <UserProxySettings>[];
  bool block = false;

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    seen.add(settings);
    if (block) return const OutboundClientBlocked('no route');
    return OutboundClientReady(MockClient(handler));
  }
}

void main() {
  final via = UserProxySettings(
    type: ProxyType.SOCKS5,
    address: '127.0.0.1:9999',
    username: kTorGeoIpTag,
    password: 'x',
  );

  group('what counts as a table', () {
    test('a well-formed table under the reviewed licence', () {
      expect(isTorGeoIpTable(_table()), isTrue);
      expect(isTorGeoIpTable(_table(eol: '\r\n')), isTrue);
    });

    test('a table under any other licence is refused', () {
      // Accepting it would be running on data whose terms nobody reviewed.
      expect(isTorGeoIpTable(_table(licence: 'CC BY-NC 4.0')), isFalse);
      expect(isTorGeoIpTable(_table().replaceFirst(RegExp('# License:.*\n'), '')),
          isFalse);
    });

    test('a malformed row refuses the whole file', () {
      expect(isTorGeoIpTable('${_table()}<html>Sign in</html>\n'), isFalse);
      expect(isTorGeoIpTable('${_table()}1,2,bra\n'), isFalse);
    });

    test('a truncated table is refused', () {
      expect(isTorGeoIpTable(_table(rows: 10)), isFalse);
      expect(isTorGeoIpTable(''), isFalse);
    });
  });

  group('file names', () {
    test('round-trip the fetch time', () {
      final at = DateTime.utc(2026, 9, 23, 12);
      expect(torGeoIpFetchedAt(torGeoIpFileName(at)), at);
    });

    test('anything else is not a table', () {
      expect(torGeoIpFetchedAt('geoip'), isNull);
      expect(torGeoIpFetchedAt('geoip-123.part'), isNull);
      expect(torGeoIpFetchedAt('other-123'), isNull);
    });

    test('a newer download gets a new path, so tor reloads it', () {
      final a = torGeoIpFileName(DateTime.utc(2026, 9, 1));
      final b = torGeoIpFileName(DateTime.utc(2026, 10, 1));
      expect(a, isNot(b));
    });
  });

  group('IoTorGeoIpStore', () {
    late Directory root;
    late DateTime now;
    late List<String> requested;
    late Map<String, http.Response Function()> answers;
    late _Factory factory;

    IoTorGeoIpStore store() =>
        IoTorGeoIpStore(overrideRoot: root, clock: () => now);

    setUp(() {
      root = Directory.systemTemp.createTempSync('tor_geoip_test');
      now = DateTime.utc(2026, 9, 23);
      requested = [];
      answers = {};
      factory = _Factory((request) async {
        final url = request.url.toString();
        requested.add(url);
        final answer = answers[url];
        return answer == null ? http.Response('', 404) : answer();
      });
      outboundHttp = factory;
    });

    tearDown(() {
      resetOutboundHttp();
      root.deleteSync(recursive: true);
    });

    test('nothing kept until something is downloaded', () async {
      expect(await store().newest(), isNull);
    });

    test('the onion service is asked first, through the given circuit',
        () async {
      answers[kTorGeoIpUrls.first] = () => http.Response(_table(), 200);
      final table = await store().download(via);

      expect(table, isNotNull);
      expect(requested, [kTorGeoIpUrls.first]);
      expect(Uri.parse(kTorGeoIpUrls.first).host, endsWith('.onion'));
      expect(factory.seen.single.username, kTorGeoIpTag,
          reason: 'never a site circuit, never direct');
      expect(File(table!.path).readAsStringSync(), _table(),
          reason: 'kept verbatim, licence header and all');
      expect((await store().newest())?.path, table.path);
    });

    test('the clearnet host is the fallback', () async {
      answers[kTorGeoIpUrls.last] = () => http.Response(_table(), 200);
      final table = await store().download(via);
      expect(table, isNotNull);
      expect(requested, kTorGeoIpUrls);
    });

    test('an answer that is not a table is never kept', () async {
      answers[kTorGeoIpUrls.first] =
          () => http.Response('<html>Sign in</html>', 200);
      answers[kTorGeoIpUrls.last] =
          () => http.Response(_table(licence: 'CC BY-NC 4.0'), 200);
      expect(await store().download(via), isNull);
      expect(await store().newest(), isNull);
    });

    test('a new download replaces the old one under a new name', () async {
      answers[kTorGeoIpUrls.first] = () => http.Response(_table(), 200);
      final first = await store().download(via);
      now = now.add(const Duration(days: 31));
      File('${root.path}/tor_geoip/geoip-1.part').writeAsStringSync('half');
      final second = await store().download(via);

      expect(second!.path, isNot(first!.path));
      expect((await store().newest())?.path, second.path);
      expect(
        Directory('${root.path}/tor_geoip').listSync().map((e) => e.path),
        [second.path],
        reason: 'older tables and partial writes are dropped',
      );
    });

    test('concurrent requests share one download', () async {
      answers[kTorGeoIpUrls.first] = () => http.Response(_table(), 200);
      final s = store();
      final both = await Future.wait([s.download(via), s.download(via)]);
      expect(requested, hasLength(1));
      expect(both[0]?.path, both[1]?.path);
    });

    test('a blocked route downloads nothing', () async {
      factory.block = true;
      expect(await store().download(via), isNull);
      expect(requested, isEmpty);
    });
  });
}
