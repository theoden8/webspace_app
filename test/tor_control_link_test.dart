// TOR-026: the app's control link to an external tor, against a fake tor
// that keeps a configuration, takes SETCONF and announces CONF_CHANGED.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/external_tor_posture_engine.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_link.dart';
import 'package:webspace/services/tor_engine.dart'
    show TorExitCountryEmpty, TorExitPinUnsupported;

import 'helpers/fake_tor_control.dart';

const _socks = (host: '127.0.0.1', port: 9050);

Future<TorControlAttach> _attach(
  FakeTorControl tor, {
  String? password,
  Map<String, Uint8List> files = const {},
}) =>
    TorControlLink.attach(
      channel: tor.connect(),
      password: password,
      readCookie: (path) async => files[path],
      socks: _socks,
    );

Future<TorControlLink> _linked(FakeTorControl tor) async =>
    ((await _attach(tor)) as TorControlLinked).link;

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('attach', () {
    test('a tor that asks for no authentication', () async {
      final link = await _linked(FakeTorControl());
      expect(link.version, '0.4.8.10');
      expect(link.posture.gaps, isEmpty);
    });

    test("the Debian tor service: SAFECOOKIE from a readable cookie", () async {
      final tor = FakeTorControl(
          methods: {TorAuthMethod.cookie, TorAuthMethod.safeCookie});
      final result = await _attach(tor,
          files: {tor.cookieFile: bytesOf(tor.cookie)});
      expect(result, isA<TorControlLinked>());
      expect(tor.commands.where((c) => c.startsWith('AUTHCHALLENGE')),
          hasLength(1));
    });

    test('a listener that does not know the cookie gets nothing derived from '
        'it', () async {
      final tor = FakeTorControl(methods: {TorAuthMethod.safeCookie});
      final secret = bytesOf(List<int>.generate(32, (i) => 200 - i));
      final result = await _attach(tor, files: {tor.cookieFile: secret});
      expect((result as TorControlNotLinked).refusal, TorControlRefusal.refused);
      expect(tor.commands.where((c) => c.startsWith('AUTHENTICATE')), isEmpty);
    });

    test('a cookie the app may not read says so', () async {
      final tor = FakeTorControl(
          methods: {TorAuthMethod.cookie, TorAuthMethod.safeCookie});
      final result = await _attach(tor) as TorControlNotLinked;
      expect(result.refusal, TorControlRefusal.cookieUnreadable);
      expect(result.detail, contains('/run/tor/control.authcookie'));
    });

    test('a password tor wants', () async {
      final tor = FakeTorControl(
          methods: {TorAuthMethod.hashedPassword}, password: 'hunter2');
      expect(await _attach(tor, password: 'hunter2'), isA<TorControlLinked>());
      expect(
          ((await _attach(FakeTorControl(
                  methods: {TorAuthMethod.hashedPassword},
                  password: 'hunter2'))) as TorControlNotLinked)
              .refusal,
          TorControlRefusal.needsPassword);
      expect(
          ((await _attach(
                  FakeTorControl(
                      methods: {TorAuthMethod.hashedPassword},
                      password: 'hunter2'),
                  password: 'wrong')) as TorControlNotLinked)
              .refusal,
          TorControlRefusal.refused);
    });

    test('a control port whose tor is not the one at the SOCKS address',
        () async {
      final result = await _attach(
              FakeTorControl(socksListeners: ['127.0.0.1:9150']))
          as TorControlNotLinked;
      expect(result.refusal, TorControlRefusal.otherTor);
    });

    test('reads the posture', () async {
      final link = await _linked(FakeTorControl(torrc: {
        'SocksPort': ['9050 IsolateDestAddr'],
        'ExitNodes': ['{us}'],
        'SafeLogging': ['1'],
        'StrictNodes': ['0'],
        'ConfluxEnabled': ['auto'],
      }));
      expect(link.posture.gaps.map((g) => g.runtimeType),
          [TorPerDestinationHost, TorOwnExits]);
    });
  });

  test('new circuits are a NEWNYM', () async {
    final tor = FakeTorControl();
    await (await _linked(tor)).newCircuits();
    expect(tor.newnyms, 1);
  });

  group('exit country', () {
    late FakeTorControl tor;
    late TorControlLink link;

    setUp(() async {
      tor = FakeTorControl(relays: [('1.1.1.1', 'nl'), ('2.2.2.2', 'de')]);
      tor.circuits = [
        '7 BUILT \$AA~a,\$BB~b,\$CC~c PURPOSE=GENERAL',
        '8 BUILT \$AA~a,\$BB~b PURPOSE=HS_CLIENT_REND',
        '9 CLOSED \$AA~a PURPOSE=GENERAL',
      ];
      link = await _linked(tor);
    });

    test('pins as the built-in tor does, and closes the old exit circuits',
        () async {
      await link.pin('{de}');
      expect(tor.config['ExitNodes'], ['{de}']);
      expect(tor.config['StrictNodes'], ['1']);
      expect(tor.config['ConfluxEnabled'], ['0']);
      expect(tor.closedCircuits, ['7']);
    });

    test('a country with no exit is refused before tor sees it', () async {
      await expectLater(link.pin('{fr}'), throwsA(isA<TorExitCountryEmpty>()));
      expect(tor.config['ExitNodes'] ?? const [], isEmpty);
    });

    test('a tor with no GeoIP cannot take a country', () async {
      tor.geoip = false;
      await expectLater(
          link.pin('{de}'), throwsA(isA<TorExitPinUnsupported>()));
      expect(tor.config['ExitNodes'] ?? const [], isEmpty);
    });

    test("clearing puts back what the tor had, its own exits included",
        () async {
      final own = FakeTorControl(
        relays: [('2.2.2.2', 'de')],
        torrc: {
          'SocksPort': ['9050'],
          'ExitNodes': ['{us}'],
          'StrictNodes': ['0'],
          'ConfluxEnabled': ['auto'],
        },
      );
      final ownLink = await _linked(own);
      await ownLink.pin('{de}');
      await ownLink.pin(null);
      expect(own.config['ExitNodes'], ['{us}']);
      expect(own.config['StrictNodes'], ['0']);
      expect(own.config['ConfluxEnabled'], ['auto']);

      await link.pin('{de}');
      await link.pin(null);
      expect(tor.config['ExitNodes'], isEmpty);
    });

    test('closing the link puts the exits back', () async {
      await link.pin('{de}');
      await link.close();
      expect(tor.config['ExitNodes'], isEmpty);
      expect(tor.config['StrictNodes'], ['0']);
    });

    test('its own CONF_CHANGED is not mistaken for someone else\'s', () async {
      final changes = <TorControlLinkEvent>[];
      link.changes.listen(changes.add);
      await link.pin('{de}');
      await link.pin(null);
      await _settle();
      expect(changes.whereType<TorLinkLost>(), isEmpty);
    });

    test('a reload that drops the pin loses the link', () async {
      final changes = <TorControlLinkEvent>[];
      link.changes.listen(changes.add);
      await link.pin('{de}');
      tor.reload();
      await _settle();
      expect(changes.whereType<TorLinkLost>(), hasLength(1));
    });

    test('a change of its own while nothing is pinned is read again',
        () async {
      final changes = <TorControlLinkEvent>[];
      link.changes.listen(changes.add);
      tor.torrc['ExitNodes'] = ['{ca}'];
      tor.reload();
      await _settle();
      final posture = changes.whereType<TorLinkPostureChanged>().last.posture;
      expect(posture.gaps.whereType<TorOwnExits>().single.nodes, '{ca}');
      expect(changes.whereType<TorLinkLost>(), isEmpty);

      await link.pin('{de}');
      await link.pin(null);
      expect(tor.config['ExitNodes'], ['{ca}'],
          reason: "the tor's exits as they now are, not as they were");
    });

    test('tor going away loses the link', () async {
      final changes = <TorControlLinkEvent>[];
      link.changes.listen(changes.add);
      tor.hangUp();
      await _settle();
      expect(changes.whereType<TorLinkLost>(), hasLength(1));
    });
  });
}
