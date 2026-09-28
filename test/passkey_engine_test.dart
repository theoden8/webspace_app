import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/passkey_engine.dart';

String b64u(List<int> bytes) => PasskeyEngine.encodeB64u(bytes);

final challengeBytes = List<int>.generate(32, (i) => i);
final challenge = b64u(challengeBytes);

Map<String, Object?> createOptions({String? rpId}) => {
      'rp': {'name': 'Example', 'id': ?rpId},
      'user': {
        'id': b64u([1, 2, 3, 4]),
        'name': 'alice',
        'displayName': 'Alice',
      },
      'challenge': challenge,
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
      ],
    };

Map<String, Object?> getOptions({String? rpId}) => {
      'challenge': challenge,
      'rpId': ?rpId,
    };

PasskeyPlan planFor(
  String op,
  Map<String, Object?> options, {
  String origin = 'https://login.example.com',
  String? top,
  bool isMainFrame = true,
  bool onScreen = true,
}) =>
    PasskeyEngine.plan(
      op: op,
      options: options,
      frameOrigin: origin,
      isMainFrame: isMainFrame,
      topUrl: top ?? '$origin/signin?next=/',
      onScreen: onScreen,
    );

Uint8List authDataFor(String rpId, {int flags = 0x45}) => Uint8List.fromList([
      ...sha256.convert(utf8.encode(rpId)).bytes,
      flags,
      0, 0, 0, 0,
      ...List<int>.filled(16, 0),
    ]);

/// `{"fmt":"none","attStmt":{},"authData":<bytes>}` in canonical CBOR.
Uint8List attestationObject(Uint8List authData) => Uint8List.fromList([
      0xa3,
      0x63, ...utf8.encode('fmt'), 0x64, ...utf8.encode('none'),
      0x67, ...utf8.encode('attStmt'), 0xa0,
      0x68, ...utf8.encode('authData'), 0x58, authData.length, ...authData,
    ]);

void main() {
  group('who may ask (PASSKEY-004)', () {
    test('a top-level https page asserts its own origin', () {
      final plan = planFor('create', createOptions());
      expect(plan.error, isNull);
      final c = plan.ceremony!;
      expect(c.origin, 'https://login.example.com');
      expect(c.rpId, 'login.example.com');
    });

    test('a same-origin frame may ask; a cross-origin frame may not', () {
      expect(
        planFor('get', getOptions(), isMainFrame: false).ceremony,
        isNotNull,
      );
      expect(
        planFor('get', getOptions(),
                origin: 'https://widget.other.test',
                top: 'https://login.example.com/',
                isMainFrame: false)
            .error,
        PasskeyError.crossOriginFrame,
      );
    });

    test('a main frame whose origin is no longer the one on screen is refused',
        () {
      expect(
        planFor('get', getOptions(),
                origin: 'https://login.example.com',
                top: 'https://elsewhere.example.net/')
            .error,
        PasskeyError.notAllowed,
      );
      expect(
        PasskeyEngine.plan(
          op: 'get',
          options: getOptions(),
          frameOrigin: 'https://login.example.com',
          isMainFrame: true,
          topUrl: null,
          onScreen: true,
        ).error,
        PasskeyError.notAllowed,
      );
    });

    test('a site behind another cannot raise the sheet', () {
      expect(planFor('get', getOptions(), onScreen: false).error,
          PasskeyError.notFocused);
    });

    test('plain http is refused except on loopback', () {
      expect(planFor('get', getOptions(), origin: 'http://example.com').error,
          PasskeyError.insecure);
      expect(
          planFor('get', getOptions(), origin: 'http://localhost:8443')
              .ceremony
              ?.origin,
          'http://localhost:8443');
      expect(planFor('get', getOptions(), origin: 'http://127.0.0.1:9000').error,
          isNull);
      expect(planFor('get', getOptions(), origin: 'file:///sdcard/x.html').error,
          PasskeyError.notAllowed);
    });

    test('an unknown operation or missing options is a TypeError', () {
      expect(planFor('store', getOptions()).error?.name, 'TypeError');
      expect(
        PasskeyEngine.plan(
          op: 'get',
          options: 'nope',
          frameOrigin: 'https://a.test',
          isMainFrame: true,
          topUrl: 'https://a.test/',
          onScreen: true,
        ).error?.name,
        'TypeError',
      );
    });
  });

  group('which relying party (PASSKEY-005)', () {
    test('the rp id defaults to the origin host and is written into the request',
        () {
      final create = planFor('create', createOptions()).ceremony!;
      expect((jsonDecode(create.requestJson) as Map)['rp']['id'],
          'login.example.com');
      final get = planFor('get', getOptions()).ceremony!;
      expect((jsonDecode(get.requestJson) as Map)['rpId'], 'login.example.com');
    });

    test('a registrable parent domain is accepted', () {
      expect(planFor('create', createOptions(rpId: 'example.com')).ceremony?.rpId,
          'example.com');
      expect(planFor('get', getOptions(rpId: 'EXAMPLE.com')).ceremony?.rpId,
          'example.com');
    });

    test('a public suffix, a sibling or an unrelated domain is a SecurityError',
        () {
      for (final rpId in ['com', 'other.example.com', 'example.org', 'ample.com']) {
        expect(planFor('get', getOptions(rpId: rpId)).error, PasskeyError.badRpId,
            reason: rpId);
      }
      expect(
        planFor('get', getOptions(rpId: 'github.io'),
                origin: 'https://victim.github.io')
            .error,
        PasskeyError.badRpId,
      );
      expect(
        planFor('get', getOptions(rpId: 'co.uk'), origin: 'https://shop.co.uk')
            .error,
        PasskeyError.badRpId,
      );
    });

    test('an IP origin can only name itself', () {
      expect(PasskeyEngine.isValidRpId('127.0.0.1', '127.0.0.1'), isTrue);
      expect(PasskeyEngine.isValidRpId('0.0.1', '127.0.0.1'), isFalse);
    });

    test('localhost is its own relying party', () {
      expect(PasskeyEngine.isValidRpId('localhost', 'localhost'), isTrue);
    });
  });

  group('the request itself', () {
    test('a missing challenge or oversize user id is a TypeError', () {
      final noChallenge = createOptions()..remove('challenge');
      expect(planFor('create', noChallenge).error?.name, 'TypeError');
      final bigUser = createOptions();
      (bigUser['user'] as Map)['id'] = b64u(List<int>.filled(65, 1));
      expect(planFor('create', bigUser).error?.name, 'TypeError');
      final noName = createOptions();
      (noName['user'] as Map).remove('name');
      expect(planFor('create', noName).error?.name, 'TypeError');
    });

    test('the page options are not mutated', () {
      final options = createOptions();
      planFor('create', options);
      expect((options['rp'] as Map).containsKey('id'), isFalse);
    });
  });

  group('clientDataJSON (PASSKEY-006)', () {
    test('is the L3 serialization and the hash is over its bytes', () {
      final c = planFor('create', createOptions()).ceremony!;
      expect(
        c.clientDataJson,
        '{"type":"webauthn.create","challenge":"$challenge",'
        '"origin":"https://login.example.com","crossOrigin":false}',
      );
      expect(c.clientDataHash,
          sha256.convert(utf8.encode(c.clientDataJson)).bytes);
      expect(planFor('get', getOptions()).ceremony!.clientDataJson,
          startsWith('{"type":"webauthn.get",'));
    });

    test('a padded or standard-alphabet challenge is re-encoded canonically', () {
      final padded = base64.encode(challengeBytes);
      final c = planFor('get', {'challenge': padded}).ceremony!;
      expect(jsonDecode(c.clientDataJson)['challenge'], challenge);
      expect((jsonDecode(c.requestJson) as Map)['challenge'], challenge);
    });

    test('escapes per CCDToString', () {
      expect(
        PasskeyEngine.buildClientDataJson(
            type: 'a"b', challenge: 'c\\d', origin: 'e\u0001f'),
        r'{"type":"a\"b","challenge":"c\\d","origin":"e\u0001f","crossOrigin":false}',
      );
    });

    test('the origin is the RFC 6454 serialization', () {
      expect(PasskeyEngine.serializeOrigin('https://Example.COM:443/x?y#z'),
          'https://example.com');
      expect(PasskeyEngine.serializeOrigin('http://localhost:8443/'),
          'http://localhost:8443');
      expect(PasskeyEngine.serializeOrigin('https://[::1]:8443/'),
          'https://[::1]:8443');
      expect(PasskeyEngine.serializeOrigin('about:blank'), isNull);
    });
  });

  group('the provider answer (PASSKEY-007)', () {
    test('a registration gets our clientDataJSON and its authenticatorData', () {
      final c = planFor('create', createOptions()).ceremony!;
      final authData = authDataFor('login.example.com');
      final response = jsonEncode({
        'id': 'cred-1',
        'rawId': 'cred-1',
        'response': {
          'clientDataJSON': b64u(utf8.encode('{"placeholder":true}')),
          'attestationObject': b64u(attestationObject(authData)),
          'transports': ['internal'],
        },
      });
      final out = PasskeyEngine.completeResponse(c, response);
      expect(out['ok'], isTrue);
      final credential = out['credential'] as Map;
      final r = credential['response'] as Map;
      expect(utf8.decode(base64Url.decode(base64Url.normalize(r['clientDataJSON']))),
          c.clientDataJson);
      expect(r['authenticatorData'], b64u(authData));
      expect(credential['type'], 'public-key');
      expect(credential['clientExtensionResults'], isEmpty);
    });

    test('an assertion for another relying party is not handed to the page', () {
      final c = planFor('get', getOptions()).ceremony!;
      final response = jsonEncode({
        'id': 'cred-1',
        'response': {
          'authenticatorData': b64u(authDataFor('evil.test', flags: 0x05)),
          'signature': b64u([1, 2, 3]),
        },
      });
      expect(PasskeyEngine.completeResponse(c, response)['name'],
          'NotReadableError');
    });

    test('an assertion missing its signature is unreadable', () {
      final c = planFor('get', getOptions()).ceremony!;
      final response = jsonEncode({
        'id': 'cred-1',
        'response': {
          'authenticatorData': b64u(authDataFor('login.example.com', flags: 5)),
        },
      });
      expect(PasskeyEngine.completeResponse(c, response)['ok'], isFalse);
      expect(PasskeyEngine.completeResponse(c, 'not json')['ok'], isFalse);
    });

    test('a good assertion keeps rawId and userHandle', () {
      final c = planFor('get', getOptions()).ceremony!;
      final response = jsonEncode({
        'id': 'cred-1',
        'rawId': 'cred-1',
        'response': {
          'authenticatorData': b64u(authDataFor('login.example.com', flags: 5)),
          'signature': b64u([1, 2, 3]),
          'userHandle': b64u([1, 2, 3, 4]),
        },
        'authenticatorAttachment': 'platform',
      });
      final out = PasskeyEngine.completeResponse(c, response);
      expect(out['ok'], isTrue);
      final credential = out['credential'] as Map;
      expect(credential['rawId'], 'cred-1');
      expect((credential['response'] as Map)['userHandle'], b64u([1, 2, 3, 4]));
    });

    test('attestation CBOR that is not a map yields nothing', () {
      expect(PasskeyEngine.attestationAuthData(Uint8List.fromList([0x80])),
          isNull);
      expect(PasskeyEngine.attestationAuthData(Uint8List.fromList([0xa1, 0x63])),
          isNull);
    });
  });

  group('native errors (PASSKEY-008)', () {
    test('cancelling, no passkey and nowhere to save one look the same', () {
      for (final code in ['USER_CANCELED', 'NO_CREDENTIAL', 'NO_CREATE_OPTIONS']) {
        expect(PasskeyEngine.errorForNative(code), PasskeyError.notAllowed,
            reason: code);
      }
    });

    test('the rest map to what Chromium reports', () {
      expect(PasskeyEngine.errorForNative('DOM_INVALID_STATE').name,
          'InvalidStateError');
      expect(PasskeyEngine.errorForNative('SECURITY').name, 'NotSupportedError');
      expect(PasskeyEngine.errorForNative('UNSUPPORTED').name, 'NotSupportedError');
      expect(PasskeyEngine.errorForNative('BUSY'), PasskeyError.busy);
      expect(PasskeyEngine.errorForNative('INTERRUPTED').name, 'NotReadableError');
      expect(PasskeyEngine.errorForNative('whatever').name, 'NotReadableError');
    });
  });

  test('one ceremony at a time, and only its owner ends it (PASSKEY-006)', () {
    final gate = PasskeyCeremonyGate();
    expect(gate.begin('tab1:1'), isTrue);
    expect(gate.begin('tab2:1'), isFalse);
    gate.end('tab2:1');
    expect(gate.active, 'tab1:1');
    gate.end('tab1:1');
    expect(gate.begin('tab2:1'), isTrue);
  });
}
