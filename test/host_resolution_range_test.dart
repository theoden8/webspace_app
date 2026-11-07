import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/host_resolution.dart';

// isPrivateOrLoopbackHost is the literal half of the SSRF guard shared by the
// user-script fetch (`__wsFetch`), icon fetch, media-session artwork fetch and
// the proxy test. Before SEC-048 its IPv6 branch matched only `::1`, `::` and
// the fc/fd/fe8-b prefixes, so an IPv4-mapped literal (`::ffff:127.0.0.1`) and
// an expanded loopback (`0:0:0:0:0:0:0:1`) read as public — a loopback / LAN /
// cloud-metadata reach past the guard, since the resolving half judges each
// resolved address with this same function. Every row is a literal the guard
// must judge the same way however it is spelled.

void main() {
  group('isPrivateOrLoopbackHost blocks private/loopback literals', () {
    for (final h in const <String>[
      // IPv4 dotted-quad.
      '127.0.0.1', '127.1.2.3', '10.0.0.1', '172.16.0.1', '172.31.255.1',
      '192.168.1.1', '169.254.169.254', '0.0.0.0',
      // IPv6 canonical.
      '::1', '::', 'fc00::1', 'fd12:3456::1', 'fe80::1',
      // IPv6 spellings SEC-048 closes.
      '0:0:0:0:0:0:0:1', // expanded loopback
      '::ffff:127.0.0.1', // IPv4-mapped loopback
      '::ffff:169.254.169.254', // IPv4-mapped cloud metadata
      '::ffff:10.0.0.1', // IPv4-mapped private
      '::ffff:7f00:1', // IPv4-mapped loopback, hex form
      '::127.0.0.1', // deprecated IPv4-compatible
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
      // Just outside the private ranges.
      '172.15.0.1', '172.32.0.1', '192.167.0.1',
      // Public IPv6, including a mapped public address.
      '2001:4860:4860::8888', '2606:4700:4700::1111', '::ffff:8.8.8.8',
      // Hostnames go to the resolving half, not this literal check.
      'example.com', 'nas.example.com', 'not-localhost.example',
    ]) {
      test('allows $h', () {
        expect(isPrivateOrLoopbackHost(h), isFalse, reason: h);
      });
    }
  });
}
