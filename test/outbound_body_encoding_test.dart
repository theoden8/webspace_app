import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/services/outbound_http.dart';

typedef _Seen = ({int? length, List<int> bytes});

/// DL-006: a download's progress is the bytes that arrive against the
/// server's Content-Length, so the seam hands out a client that leaves a
/// compressed body as sent. Over a real socket: flutter_test's binding
/// would answer every request with an empty 400.
void main() {
  late HttpServer server;
  final plain = List.filled(4096, 7);
  final body = gzip.encode(plain);

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    server.listen((request) {
      request.response
        ..headers.set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..contentLength = body.length
        ..add(body);
      unawaited(request.response.close());
    });
  });

  tearDown(() => server.close(force: true));

  Future<_Seen> fetch(BodyEncoding encoding) async {
    final result = const DefaultOutboundHttpFactory().clientFor(
      OutboundProxy.app.resolved,
      encoding: encoding,
    );
    final client = (result as OutboundClientReady).client;
    final response = await client.send(
      http.Request('GET', Uri.parse('http://127.0.0.1:${server.port}/f')),
    );
    final bytes = await response.stream.toBytes();
    client.close();
    return (length: response.contentLength, bytes: bytes);
  }

  test('DL-006: a body as sent is the bytes its length counts', () async {
    final seen = await fetch(BodyEncoding.asSent);
    expect(seen.bytes, body);
    expect(seen.length, seen.bytes.length);
  });

  test('a decoded body is not what its length counts', () async {
    final seen = await fetch(BodyEncoding.decoded);
    expect(seen.bytes, plain);
    expect(seen.length, isNot(seen.bytes.length));
  });
}
