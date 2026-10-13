// TOR-026: the control protocol pieces the external tor's link is built on.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/tor_control.dart';

import 'helpers/fake_tor_control.dart';

List<TorControlReply> _frame(List<String> lines) {
  final out = <TorControlReply>[];
  final framer = TorControlFramer(onMessage: out.add);
  for (final line in lines) {
    framer.addLine(line);
  }
  return out;
}

void main() {
  group('TorControlEndpoint.parse', () {
    test('a path is a Unix socket, with or without tor\'s unix: prefix', () {
      expect((TorControlEndpoint.parse('/run/tor/control') as TorControlSocket)
          .path, '/run/tor/control');
      expect(
          (TorControlEndpoint.parse(' unix:/run/tor/control ')
                  as TorControlSocket)
              .path,
          '/run/tor/control');
    });

    test('host:port is TCP', () {
      final tcp = TorControlEndpoint.parse('127.0.0.1:9051') as TorControlTcp;
      expect(tcp.host, '127.0.0.1');
      expect(tcp.port, 9051);
    });

    test('anything else is nothing', () {
      for (final raw in ['', '9051', 'localhost', 'run/tor/control', ':9051']) {
        expect(TorControlEndpoint.parse(raw), isNull, reason: raw);
      }
    });
  });

  group('TorControlFramer', () {
    test('a multi-line reply is one message', () {
      final replies = _frame([
        '250-PROTOCOLINFO 1',
        '250-AUTH METHODS=NULL',
        '250 OK',
      ]);
      expect(replies, hasLength(1));
      expect(replies.single.status, 250);
      expect(replies.single.lines, ['PROTOCOLINFO 1', 'AUTH METHODS=NULL', 'OK']);
    });

    test('a data block is joined and dot-unescaped', () {
      final replies = _frame([
        '250+ns/all=',
        'r a',
        '..dotted',
        '.',
        '250 OK',
      ]);
      expect(replies.single.lines, ['ns/all=r a\n.dotted', 'OK']);
    });

    test('an event is told from a reply', () {
      final replies = _frame([
        '650-CONF_CHANGED',
        '650-ExitNodes={de}',
        '650 OK',
        '250 OK',
      ]);
      expect(replies.map((r) => r.isEvent), [true, false]);
    });

    test('a line that is not tor\'s is refused', () {
      expect(() => _frame(['HTTP/1.0 400 Bad Request']),
          throwsA(isA<FormatException>()));
    });
  });

  test('torQuoted escapes, a line break included', () {
    expect(torQuoted(r'pa"ss\word'), r'"pa\"ss\\word"');
    expect(torQuoted('a\r\nSIGNAL HALT'), r'"a\r\nSIGNAL HALT"',
        reason: 'a value never ends the command it is in');
  });

  group('PROTOCOLINFO', () {
    TorProtocolInfo? info(List<String> lines) =>
        TorProtocolInfo.fromReply(_frame(lines).single);

    test('methods, cookie file and version', () {
      final read = info([
        '250-PROTOCOLINFO 1',
        r'250-AUTH METHODS=COOKIE,SAFECOOKIE,HASHEDPASSWORD COOKIEFILE="/run/tor/control.authcookie"',
        '250-VERSION Tor="0.4.8.10"',
        '250 OK',
      ])!;
      expect(read.methods, {
        TorAuthMethod.cookie,
        TorAuthMethod.safeCookie,
        TorAuthMethod.hashedPassword,
      });
      expect(read.cookieFile, '/run/tor/control.authcookie');
      expect(read.version, '0.4.8.10');
    });

    test('an answer that is not PROTOCOLINFO is not tor', () {
      expect(info(['250 OK']), isNull);
      expect(info(['514 Authentication required.']), isNull);
    });
  });

  group('planTorAuth', () {
    TorProtocolInfo offering(Set<TorAuthMethod> methods) => TorProtocolInfo(
        methods: methods, cookieFile: '/c', version: null);
    final cookie = bytesOf(List<int>.generate(32, (i) => i));

    test('no authentication when tor asks for none', () {
      expect(
          planTorAuth(
              info: offering({TorAuthMethod.none, TorAuthMethod.cookie}),
              password: 'x',
              cookie: cookie),
          isA<TorAuthNull>());
    });

    test('a saved password before the cookie', () {
      expect(
          planTorAuth(
              info: offering(
                  {TorAuthMethod.hashedPassword, TorAuthMethod.safeCookie}),
              password: 'secret',
              cookie: cookie),
          isA<TorAuthPassword>());
    });

    test('SAFECOOKIE from the cookie', () {
      expect(
          planTorAuth(
              info: offering({TorAuthMethod.cookie, TorAuthMethod.safeCookie}),
              password: null,
              cookie: cookie),
          isA<TorAuthSafeCookie>());
    });

    test('never plain COOKIE, which would send whatever file the listener '
        'named', () {
      final plan = planTorAuth(
          info: offering({TorAuthMethod.cookie}),
          password: null,
          cookie: cookie);
      expect((plan as TorAuthImpossible).refusal, TorControlRefusal.refused);
    });

    test('a cookie of the wrong length is not tor\'s', () {
      final plan = planTorAuth(
          info: offering({TorAuthMethod.safeCookie}),
          password: null,
          cookie: bytesOf([1, 2, 3]));
      expect((plan as TorAuthImpossible).refusal,
          TorControlRefusal.cookieUnreadable);
    });

    test('says what is missing', () {
      final noPassword = planTorAuth(
          info: offering(
              {TorAuthMethod.hashedPassword, TorAuthMethod.safeCookie}),
          password: null,
          cookie: null);
      expect((noPassword as TorAuthImpossible).refusal,
          TorControlRefusal.needsPassword);
      final noCookie = planTorAuth(
          info: offering({TorAuthMethod.safeCookie}),
          password: 'unused',
          cookie: null);
      expect((noCookie as TorAuthImpossible).refusal,
          TorControlRefusal.cookieUnreadable);
    });
  });

  test('SAFECOOKIE hashes are control-spec 3.24\'s HMACs', () {
    final exchange = TorSafeCookieExchange(
      cookie: List<int>.filled(32, 1),
      clientNonce: List<int>.filled(32, 2),
      serverNonce: List<int>.filled(32, 3),
    );
    final message = [
      ...List<int>.filled(32, 1),
      ...List<int>.filled(32, 2),
      ...List<int>.filled(32, 3),
    ];
    Digest mac(String key) =>
        Hmac(sha256, ascii.encode(key)).convert(message);
    expect(exchange.serverHash,
        mac('Tor safe cookie authentication server-to-controller hash').bytes);
    expect(exchange.clientHash,
        mac('Tor safe cookie authentication controller-to-server hash').bytes);
  });

  test('GETCONF lines keep every value, and a default reads as null', () {
    final values = torKeyValues(_frame([
      '250-SocksPort=9050',
      '250-SocksPort=unix:/run/tor/socks WorldWritable',
      '250 ExitNodes',
    ]).single);
    expect(values['SocksPort'], ['9050', 'unix:/run/tor/socks WorldWritable']);
    expect(values['ExitNodes'], [null]);
  });

  test('net/listeners/socks is a list of quoted strings', () {
    expect(torQuotedList(r'"127.0.0.1:9050" "unix:/run/tor/socks"'),
        ['127.0.0.1:9050', 'unix:/run/tor/socks']);
  });
}
