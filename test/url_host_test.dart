import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/url_host.dart';

void main() {
  group('Host', () {
    test('folds case, IPv6 brackets, a root dot and surrounding space', () {
      expect(Host(' NAS.Example.com. '), 'nas.example.com');
      expect(Host('[::1]'), '::1');
      expect(Host('example.com'), 'example.com');
    });

    test('withoutWww folds exactly one leading www.', () {
      expect(Host('WWW.Example.com').withoutWww, 'example.com');
      expect(Host('www.www.a.com').withoutWww, 'www.a.com');
      expect(Host('awww.com').withoutWww, 'awww.com');
    });

    test('ofWebUrl takes only http(s) URLs with a host', () {
      expect(Host.ofWebUrl('https://Example.COM./x'), 'example.com');
      expect(Host.ofWebUrl('http://[2001:db8::1]:8080/'), '2001:db8::1');
      expect(Host.ofWebUrl('file:///a.html'), isNull);
      expect(Host.ofWebUrl('about:blank'), isNull);
      expect(Host.ofWebUrl(null), isNull);
    });

    test('inUrl takes any scheme that names a host', () {
      expect(Host.inUrl('wss://Example.COM./x'), 'example.com');
      expect(Host.inUrl('http://[2001:db8::1]:8080/'), '2001:db8::1');
      expect(Host.inUrl('file:///a.html'), isNull);
      expect(Host.inUrl('about:blank'), isNull);
      expect(Host.inUrl(null), isNull);
    });
  });

  // The cases the five hand-written checks this owner replaced answered
  // differently: the proxy bypass missed 127.0.0.2, the router's challenge
  // check missed ::1, the passkey check took 127.999.0.1.
  group('Host loopback', () {
    test('a loopback literal is an address on the loopback interface', () {
      for (final (raw, literal) in [
        ('127.0.0.1', true),
        ('127.0.0.2', true),
        ('127.255.255.254', true),
        ('::1', true),
        ('[::1]', true),
        ('0:0:0:0:0:0:0:1', true),
        ('::ffff:127.0.0.1', true),
        ('128.0.0.1', false),
        ('127.0.0', false),
        ('127.0.0.256', false),
        ('127.999.0.1', false),
        ('::', false),
        ('::ffff:10.0.0.1', false),
        ('localhost', false),
        ('a.localhost', false),
        ('example.com', false),
      ]) {
        expect(Host(raw).isLoopbackLiteral, literal, reason: raw);
      }
    });

    test('loopback as a secure context reads it adds localhost and names '
        'under it', () {
      for (final (raw, loopback) in [
        ('localhost', true),
        ('LOCALHOST.', true),
        ('dev.localhost', true),
        ('127.0.0.2', true),
        ('[::1]', true),
        ('localhost.example', false),
        ('notlocalhost', false),
        ('203.0.113.9', false),
      ]) {
        expect(Host(raw).isLoopback, loopback, reason: raw);
      }
    });
  });

  group('extractDomain', () {
    test('returns the host of a URL', () {
      expect(extractDomain('https://example.com'), 'example.com');
      expect(extractDomain('https://sub.example.com/path?query=1'),
          'sub.example.com');
      expect(extractDomain('http://example.com:8080/path'), 'example.com');
    });

    test('returns anything without a host unchanged', () {
      expect(extractDomain('example.com'), 'example.com');
      expect(extractDomain('not a url'), 'not a url');
      expect(extractDomain(''), '');
    });
  });
}
