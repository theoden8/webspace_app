import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webspace/services/download_engine.dart';

void main() {
  group('DownloadEngine.buildCookieHeader', () {
    test('returns null for empty input', () {
      expect(DownloadEngine.buildCookieHeader(const []), isNull);
    });

    test('joins name=value pairs with "; "', () {
      final header = DownloadEngine.buildCookieHeader([
        const MapEntry('sessionid', 'abc123'),
        const MapEntry('theme', 'dark'),
      ]);
      expect(header, 'sessionid=abc123; theme=dark');
    });

    test('preserves insertion order', () {
      final header = DownloadEngine.buildCookieHeader([
        const MapEntry('b', '2'),
        const MapEntry('a', '1'),
      ]);
      expect(header, 'b=2; a=1');
    });
  });

  group('DownloadEngine.deriveFilename', () {
    test('suggested name wins over URL and mime', () {
      final name = DownloadEngine.deriveFilename(
        suggested: 'report.pdf',
        url: 'https://example.com/path/something.bin',
        mimeType: 'application/zip',
      );
      expect(name, 'report.pdf');
    });

    test('falls back to last path segment when no suggestion', () {
      final name = DownloadEngine.deriveFilename(
        suggested: null,
        url: 'https://example.com/files/budget%202026.xlsx',
      );
      expect(name, 'budget 2026.xlsx');
    });

    test('skips trailing empty segments from trailing slash', () {
      final name = DownloadEngine.deriveFilename(
        suggested: '',
        url: 'https://example.com/path/foo.txt/',
      );
      expect(name, 'foo.txt');
    });

    test('falls back to download.<ext> from mime when URL has no filename',
        () {
      final name = DownloadEngine.deriveFilename(
        suggested: null,
        url: 'https://example.com/',
        mimeType: 'application/pdf',
      );
      expect(name, 'download.pdf');
    });

    test('generic download when nothing is known', () {
      final name = DownloadEngine.deriveFilename(
        suggested: null,
        url: 'https://example.com/',
      );
      expect(name, 'download');
    });

    test('sanitizes path separators', () {
      expect(
        DownloadEngine.deriveFilename(
          suggested: '../../etc/passwd',
          url: 'https://example.com/',
        ),
        '.._.._etc_passwd',
      );
      expect(
        DownloadEngine.deriveFilename(
          suggested: r'..\..\win.ini',
          url: 'https://example.com/',
        ),
        r'.._.._win.ini',
      );
    });

    test('strips control characters', () {
      final name = DownloadEngine.deriveFilename(
        suggested: 'file\x00\x01.pdf',
        url: 'https://example.com/',
      );
      expect(name, 'file.pdf');
    });
  });

  group('DownloadEngine.fetch', () {
    test('forwards cookie and user-agent headers', () async {
      Map<String, String>? capturedHeaders;
      final client = MockClient((request) async {
        capturedHeaders = request.headers;
        return http.Response('hello', 200,
            headers: {'content-type': 'text/plain'});
      });

      final engine = DownloadEngine(client: client);
      await engine.fetch(
        url: 'https://example.com/f.txt',
        cookieHeader: 'sid=xyz; theme=dark',
        userAgent: 'TestAgent/1.0',
      );

      expect(capturedHeaders?['cookie'], 'sid=xyz; theme=dark');
      expect(capturedHeaders?['user-agent'], 'TestAgent/1.0');
    });

    test('does not send cookie header when none supplied', () async {
      Map<String, String>? capturedHeaders;
      final client = MockClient((request) async {
        capturedHeaders = request.headers;
        return http.Response('x', 200);
      });
      await DownloadEngine(client: client)
          .fetch(url: 'https://example.com/f');
      expect(capturedHeaders, isNotNull);
      expect(capturedHeaders!.containsKey('cookie'), isFalse);
    });

    test('returns bytes and parsed mime', () async {
      final body = Uint8List.fromList(utf8.encode('pdf-bytes'));
      final client = MockClient((request) async => http.Response.bytes(
            body,
            200,
            headers: {'content-type': 'application/pdf; charset=binary'},
          ));

      final result = await DownloadEngine(client: client).fetch(
        url: 'https://example.com/doc.pdf',
      );

      expect(result.bytes, body);
      expect(result.mimeType, 'application/pdf');
      expect(result.filename, 'doc.pdf');
    });

    test('throws on non-2xx status', () async {
      final client = MockClient(
          (request) async => http.Response('not found', 404));
      expect(
        () => DownloadEngine(client: client)
            .fetch(url: 'https://example.com/missing'),
        throwsA(isA<DownloadException>().having(
            (e) => e.message, 'message', contains('404'))),
      );
    });

    test('throws on network error', () async {
      final client =
          MockClient((request) async => throw const SocketExceptionStub());
      expect(
        () => DownloadEngine(client: client)
            .fetch(url: 'https://example.com/x'),
        throwsA(isA<DownloadException>().having(
            (e) => e.message, 'message', contains('Network error'))),
      );
    });

    test('rejects non-http schemes before any I/O', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      expect(
        () => DownloadEngine(client: client).fetch(url: 'blob:abc'),
        throwsA(isA<DownloadException>().having(
            (e) => e.message, 'message', contains('Unsupported scheme'))),
      );
      // Ensure the client was never called.
      await Future<void>.delayed(Duration.zero);
      expect(called, isFalse);
    });

    test('suggestedFilename wins over URL-derived name', () async {
      final client = MockClient((_) async => http.Response('ok', 200));
      final result = await DownloadEngine(client: client).fetch(
        url: 'https://example.com/opaque?x=1',
        suggestedFilename: 'invoice.pdf',
      );
      expect(result.filename, 'invoice.pdf');
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: connection refused';
}
