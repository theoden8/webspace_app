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

    test('streams progress callbacks with known total', () async {
      final payload = Uint8List.fromList(List<int>.filled(1024, 42));
      final client = MockClient.streaming((request, bodyStream) async {
        Stream<List<int>> chunks() async* {
          yield payload.sublist(0, 256);
          yield payload.sublist(256, 512);
          yield payload.sublist(512, 1024);
        }
        return http.StreamedResponse(
          chunks(),
          200,
          contentLength: payload.length,
          headers: {'content-type': 'application/octet-stream'},
        );
      });

      final events = <(int, int?)>[];
      final result = await DownloadEngine(client: client).fetch(
        url: 'https://example.com/big.bin',
        onProgress: (done, total) => events.add((done, total)),
      );

      expect(result.bytes, payload);
      // First event is initial (0, total); last event is full.
      expect(events.first, (0, 1024));
      expect(events.last, (1024, 1024));
      // Monotonic non-decreasing done.
      for (var i = 1; i < events.length; i++) {
        expect(events[i].$1 >= events[i - 1].$1, isTrue);
      }
    });

    test('streams progress with unknown total (no Content-Length)', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        Stream<List<int>> chunks() async* {
          yield [1, 2, 3];
          yield [4, 5];
        }
        return http.StreamedResponse(chunks(), 200);
      });

      final events = <(int, int?)>[];
      final result = await DownloadEngine(client: client).fetch(
        url: 'https://example.com/unknown',
        onProgress: (done, total) => events.add((done, total)),
      );

      expect(result.bytes, [1, 2, 3, 4, 5]);
      expect(events.first.$2, isNull);
      expect(events.last.$1, 5);
    });
  });

  group('DownloadEngine.decodeDataUri', () {
    test('decodes base64 payload', () {
      final result = DownloadEngine.decodeDataUri(
        url: 'data:text/plain;base64,SGVsbG8=',
      );
      expect(utf8.decode(result.bytes), 'Hello');
      expect(result.mimeType, 'text/plain');
      expect(result.filename, 'download.txt');
    });

    test('decodes URL-encoded payload', () {
      final result = DownloadEngine.decodeDataUri(
        url: 'data:text/plain,Hello%20world',
      );
      expect(utf8.decode(result.bytes), 'Hello world');
      expect(result.mimeType, 'text/plain');
    });

    test('handles data URI without explicit mime (RFC 2397 default)', () {
      // Per RFC 2397, an absent mime means text/plain. Dart's UriData
      // reports that as the mimeType, so we surface it too.
      final result = DownloadEngine.decodeDataUri(
        url: 'data:;base64,SGVsbG8=',
      );
      expect(result.bytes, utf8.encode('Hello'));
      expect(result.mimeType, 'text/plain');
    });

    test('suggested filename wins over mime-derived fallback', () {
      final result = DownloadEngine.decodeDataUri(
        url: 'data:application/pdf;base64,JVBERi0=',
        suggestedFilename: 'invoice.pdf',
      );
      expect(result.filename, 'invoice.pdf');
    });

    test('rejects non-data URI', () {
      expect(
        () => DownloadEngine.decodeDataUri(
            url: 'https://example.com/file'),
        throwsA(isA<DownloadException>()),
      );
    });
  });

  group('DownloadEngine.fromBase64', () {
    test('decodes base64 and applies suggested filename + mime', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final payload = base64.encode(bytes);
      final result = DownloadEngine.fromBase64(
        base64Data: payload,
        suggestedFilename: 'note.txt',
        mimeType: 'text/plain',
      );
      expect(result.bytes, bytes);
      expect(result.filename, 'note.txt');
      expect(result.mimeType, 'text/plain');
    });

    test('derives filename from mime when no suggestion', () {
      final payload = base64.encode([1, 2, 3]);
      final result = DownloadEngine.fromBase64(
        base64Data: payload,
        mimeType: 'application/pdf',
      );
      expect(result.filename, 'download.pdf');
    });

    test('throws DownloadException on malformed base64', () {
      expect(
        () => DownloadEngine.fromBase64(base64Data: '!!!not-base64!!!'),
        throwsA(isA<DownloadException>().having(
            (e) => e.message, 'message', contains('Malformed base64'))),
      );
    });

    test('tolerates surrounding whitespace in base64', () {
      final payload = '  ${base64.encode(utf8.encode('ok'))}  ';
      final result = DownloadEngine.fromBase64(base64Data: payload);
      expect(utf8.decode(result.bytes), 'ok');
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: connection refused';
}
