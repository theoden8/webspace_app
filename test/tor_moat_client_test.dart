// TOR-016 moat: the exchange that gets bridges when the network blocks Tor.
//
// Response shapes here were captured from the live BridgeDB service, not
// copied from its documentation — the docs are stale on three points that
// would each have been a bug (`transport` is a list, the captcha is JPEG,
// and `challenge` currently holds the transport name rather than an opaque
// token). The client must survive all of those and their reversal.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/services/tor_moat_client.dart';

/// 1x1 JPEG. Small enough to inline, real enough that base64 decoding it
/// proves the path rather than a stub.
const _jpegB64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
    'AAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

/// Shape-invented: a live line would rotate, and committing one burns it.
const _obfs4 =
    'obfs4 192.0.2.10:9443 A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 '
    'cert=abcdEFGH1234ijklMNOP5678qrstUVWX90yzABcdEFghIJklMNop iat-mode=0';

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);
  final http.Response Function(http.Request request) handler;
  final requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    requests.add(req);
    final res = handler(req);
    return http.StreamedResponse(
      Stream.value(utf8.encode(res.body)),
      res.statusCode,
      headers: res.headers,
    );
  }
}

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  group('fetchChallenge', () {
    test('parses the live response shape', () async {
      // Exactly what the service returns today: transport as a LIST, and a
      // challenge that is merely the transport name.
      final fake = _FakeClient((_) => _json({
            'data': [
              {
                'id': '1',
                'type': 'moat-challenge',
                'version': '0.1.0',
                'transport': ['obfs4'],
                'image': _jpegB64,
                'challenge': 'obfs4',
              }
            ]
          }));
      final c = await MoatClient(client: fake).fetchChallenge(
        TorTransport.obfs4,
      );

      expect(c.transport, TorTransport.obfs4);
      expect(c.challenge, 'obfs4');
      expect(c.imageBytes, isA<Uint8List>());
      expect(c.imageBytes.length, greaterThan(100),
          reason: 'the captcha must actually decode, not arrive empty');
      // JPEG magic: proves we did not silently accept something undecodable.
      expect(c.imageBytes.take(2), [0xFF, 0xD8]);
    });

    test('survives challenge returning to an opaque token', () async {
      // The value is round-tripped verbatim, so a return to real tokens
      // needs no code change. This pins that.
      const token = 'YmxvYitvcGFxdWUrdG9rZW4rZXhhbXBsZQ==';
      final fake = _FakeClient((_) => _json({
            'data': [
              {'transport': ['obfs4'], 'image': _jpegB64, 'challenge': token}
            ]
          }));
      final c =
          await MoatClient(client: fake).fetchChallenge(TorTransport.obfs4);
      expect(c.challenge, token);
    });

    test('asks for the transport it was given', () async {
      final fake = _FakeClient((_) => _json({
            'data': [
              {'transport': ['snowflake'], 'image': _jpegB64, 'challenge': 'x'}
            ]
          }));
      await MoatClient(client: fake).fetchChallenge(TorTransport.snowflake);
      final sent = jsonDecode(fake.requests.single.body) as Map;
      expect((sent['data'] as List).first['supported'], ['snowflake']);
    });

    test('an unreachable service is its own failure kind', () async {
      // On a censored network this is the expected outcome, and the UI must
      // not report it as "the service is down".
      final fake = _FakeClient((_) => throw Exception('no route'));
      await expectLater(
        MoatClient(client: fake).fetchChallenge(TorTransport.obfs4),
        throwsA(isA<MoatException>()
            .having((e) => e.kind, 'kind', MoatErrorKind.unreachable)),
      );
    });

    test('a non-200 is unreachable, not malformed', () async {
      final fake = _FakeClient((_) => http.Response('nope', 503));
      await expectLater(
        MoatClient(client: fake).fetchChallenge(TorTransport.obfs4),
        throwsA(isA<MoatException>()
            .having((e) => e.kind, 'kind', MoatErrorKind.unreachable)),
      );
    });

    test('junk or a missing captcha is malformed', () async {
      for (final body in <Object>[
        {'data': []},
        {'data': [{'challenge': 'obfs4'}]},
        {'data': [{'image': 'not!base64!', 'challenge': 'obfs4'}]},
      ]) {
        final fake = _FakeClient((_) => _json(body));
        await expectLater(
          MoatClient(client: fake).fetchChallenge(TorTransport.obfs4),
          throwsA(isA<MoatException>()
              .having((e) => e.kind, 'kind', MoatErrorKind.malformed)),
          reason: '$body',
        );
      }
    });
  });

  group('submitSolution', () {
    MoatChallenge challenge() => MoatChallenge(
          transport: TorTransport.obfs4,
          challenge: 'obfs4',
          imageBytes: Uint8List.fromList([0xFF, 0xD8]),
        );

    test('returns parsed bridge lines', () async {
      final fake = _FakeClient((_) => _json({
            'data': [
              {'type': 'moat-bridges', 'bridges': [_obfs4], 'qrcode': null}
            ]
          }));
      final lines =
          await MoatClient(client: fake).submitSolution(challenge(), 'abcd');

      expect(lines.single.raw, _obfs4);
      expect(lines.single.transport, TorTransport.obfs4);
    });

    test('round-trips the challenge token and the solution', () async {
      final fake = _FakeClient((_) => _json({
            'data': [{'bridges': [_obfs4]}]
          }));
      await MoatClient(client: fake).submitSolution(challenge(), 'my-answer');

      final sent = (jsonDecode(fake.requests.single.body) as Map)['data'] as List;
      expect(sent.first['challenge'], 'obfs4');
      expect(sent.first['solution'], 'my-answer');
      expect(sent.first['transport'], 'obfs4');
    });

    test('an errors document is a rejected solution', () async {
      // Not reachable today — BridgeDB accepts any solution — but the branch
      // has to exist for the day validation comes back, or a wrong captcha
      // would surface as "malformed response".
      final fake = _FakeClient((_) => _json({
            'errors': [
              {'id': '4', 'type': 'moat-bridges', 'detail': 'Wrong solution.'}
            ]
          }));
      await expectLater(
        MoatClient(client: fake).submitSolution(challenge(), 'wrong'),
        throwsA(isA<MoatException>()
            .having((e) => e.kind, 'kind', MoatErrorKind.wrongSolution)
            .having((e) => e.detail, 'detail', contains('Wrong solution'))),
      );
    });

    test('a transport this build cannot run is skipped, not fatal', () async {
      // BridgeDB may hand out something we do not implement; one such line
      // must not discard the usable ones.
      final fake = _FakeClient((_) => _json({
            'data': [
              {
                'bridges': ['obfs3 192.0.2.9:1 DEADBEEF', _obfs4]
              }
            ]
          }));
      final lines =
          await MoatClient(client: fake).submitSolution(challenge(), 'x');
      expect(lines.length, 1);
      expect(lines.single.raw, _obfs4);
    });

    test('an empty solution is what obtainBridges sends first', () async {
      // Verified against the live service: BridgeDB issues a captcha and
      // then accepts any answer, empty included. Making someone read
      // distorted text that is not checked is pure friction.
      final fake = _FakeClient((req) {
        if (req.url.path.endsWith('/fetch')) {
          return _json({
            'data': [
              {'transport': ['obfs4'], 'image': _jpegB64, 'challenge': 'obfs4'}
            ]
          });
        }
        return _json({
          'data': [{'bridges': [_obfs4]}]
        });
      });

      final result =
          await MoatClient(client: fake).obtainBridges(TorTransport.obfs4);

      expect(result, isA<MoatBridgesObtained>());
      expect((result as MoatBridgesObtained).lines.single.raw, _obfs4);

      final check = fake.requests.last;
      final sent = (jsonDecode(check.body) as Map)['data'] as List;
      expect(sent.first['solution'], '',
          reason: 'an honest empty answer, never a forged one');
    });

    test('a service that rejects the empty answer asks for the captcha',
        () async {
      final fake = _FakeClient((req) {
        if (req.url.path.endsWith('/fetch')) {
          return _json({
            'data': [
              {'transport': ['obfs4'], 'image': _jpegB64, 'challenge': 'tok'}
            ]
          });
        }
        return _json({
          'errors': [{'detail': 'Wrong solution.'}]
        });
      });

      final result =
          await MoatClient(client: fake).obtainBridges(TorTransport.obfs4);

      expect(result, isA<MoatCaptchaRequired>());
      // The same challenge is handed back, so the user's answer goes with
      // the token the captcha was issued for.
      expect((result as MoatCaptchaRequired).challenge.challenge, 'tok');
      expect(result.challenge.imageBytes.take(2), [0xFF, 0xD8]);
    });

    test('an unreachable service is not turned into a captcha prompt',
        () async {
      // No human can solve "no route". Only a rejected solution becomes a
      // prompt; everything else propagates.
      final fake = _FakeClient((req) {
        if (req.url.path.endsWith('/fetch')) {
          return _json({
            'data': [
              {'transport': ['obfs4'], 'image': _jpegB64, 'challenge': 'obfs4'}
            ]
          });
        }
        throw Exception('no route');
      });
      await expectLater(
        MoatClient(client: fake).obtainBridges(TorTransport.obfs4),
        throwsA(isA<MoatException>()
            .having((e) => e.kind, 'kind', MoatErrorKind.unreachable)),
      );
    });

    test('nothing usable is its own kind, not an empty success', () async {
      // Returning an empty list would leave the UI saying "saved" with no
      // bridges configured.
      final fake = _FakeClient((_) => _json({
            'data': [
              {'bridges': ['obfs3 192.0.2.9:1 DEADBEEF']}
            ]
          }));
      await expectLater(
        MoatClient(client: fake).submitSolution(challenge(), 'x'),
        throwsA(isA<MoatException>()
            .having((e) => e.kind, 'kind', MoatErrorKind.noBridges)),
      );
    });
  });
}
