import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/host_resolution.dart';

// isPrivateOrLoopbackHost is the literal half of the SSRF guard shared by the
// user-script fetch (`__wsFetch`), icon fetch, media-session artwork fetch and
// the proxy test. The resolving half judges each resolved address with the same
// function, so one address must be judged the same way however it is spelled
// (SEC-048, parity). Every row names a spelling of the same address class.

void main() {
  group('isPrivateOrLoopbackHost blocks non-public literals', () {
    for (final h in const <String>[
      // IPv4 dotted-quad: loopback / private / link-local(metadata).
      '127.0.0.1', '127.1.2.3', '10.0.0.1', '172.16.0.1', '172.31.255.1',
      '192.168.1.1', '169.254.169.254', '0.0.0.0',
      // IPv4 documentation ranges (non-public).
      '192.0.2.5', '198.51.100.9', '203.0.113.7',
      // Non-canonical numeric IPv4 an inet_aton resolver would still accept.
      '127.1', '2130706433', '0x7f.0.0.1', '0177.0.0.1',
      // IPv6 canonical.
      '::1', '::', 'fc00::1', 'fd12:3456::1', 'fe80::1',
      // IPv6 loopback / mapped / compatible spellings.
      '0:0:0:0:0:0:0:1', '::ffff:127.0.0.1', '::ffff:169.254.169.254',
      '::ffff:10.0.0.1', '::ffff:7f00:1', '::127.0.0.1',
      // Other v6 forms that embed a v4 — judged by the embedded address.
      '64:ff9b::127.0.0.1', '64:ff9b::169.254.169.254', '64:ff9b:1::127.0.0.1',
      '2002:7f00:1::', // 6to4 of 127.0.0.1
      '2002:a9fe:a9fe::', // 6to4 of 169.254.169.254
      // Teredo (obfuscated v4) refused outright; IPv6 documentation; scoped;
      // site-local; multicast.
      '2001::1', '2001:db8::1', 'fe80::1%eth0', 'fec0::1', 'ff02::1', 'ff00::',
      // Normalized through Host(): brackets, case, trailing dot.
      '[::ffff:127.0.0.1]', '::FFFF:127.0.0.1', '127.0.0.1.',
      // Names.
      'localhost', 'db.localhost',
    ]) {
      test('blocks $h', () {
        expect(isPrivateOrLoopbackHost(h), isTrue, reason: h);
      });
    }
  });

  group('isPrivateOrLoopbackHost allows public literals and names', () {
    for (final h in const <String>[
      '8.8.8.8', '1.1.1.1', '93.184.216.34',
      // Just outside the private / doc ranges.
      '172.15.0.1', '172.32.0.1', '192.167.0.1', '192.0.3.1', '198.51.101.1',
      // Public IPv6, incl. mapped / NAT64 / 6to4 of a public v4.
      '2001:4860:4860::8888', '2606:4700:4700::1111', '::ffff:8.8.8.8',
      '64:ff9b::8.8.8.8', '2002:0808:0808::',
      // Hostnames go to the resolving half, not this literal check.
      'example.com', 'nas.example.com', 'not-localhost.example',
    ]) {
      test('allows $h', () {
        expect(isPrivateOrLoopbackHost(h), isFalse, reason: h);
      });
    }
  });
}
