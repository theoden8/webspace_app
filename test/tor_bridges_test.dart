// TOR-016: bridge lines and the torrc they produce.
//
// Two things are worth pinning here. Parsing, because a bridge line is
// pasted by hand under pressure and a half-copied one must say which half is
// missing rather than fail at bootstrap 10% twenty seconds later. And
// generation, because `UseBridges 1` with nothing dialable is worse than no
// bridges at all — it stops tor using the direct guards that might have
// worked.

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/services/tor_failure.dart';

// A real-shaped obfs4 line (address and keys are invented).
const _obfs4 =
    'obfs4 192.0.2.10:9443 A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 '
    'cert=abcdEFGH1234ijklMNOP5678qrstUVWX90yzABcdEFghIJklMNop iat-mode=0';

void main() {
  group('parsing', () {
    test('accepts a well-formed obfs4 line', () {
      final r = parseTorBridgeLine(_obfs4);
      expect(r.isOk, isTrue);
      expect(r.line!.transport, TorTransport.obfs4);
      expect(r.line!.raw, _obfs4);
    });

    test('tolerates a line copied straight out of a torrc', () {
      final r = parseTorBridgeLine('Bridge $_obfs4');
      expect(r.isOk, isTrue);
      expect(r.line!.raw, _obfs4,
          reason: 'the Bridge keyword is stripped, not kept and re-emitted');
    });

    test('keeps the line verbatim rather than re-serialising it', () {
      // The tail of a bridge line is transport-defined and tor is the
      // authority on it; rebuilding it from parsed parts risks corrupting a
      // line the user pasted correctly.
      const spaced = 'obfs4 192.0.2.10:9443 DEADBEEF cert=zz iat-mode=1';
      expect(parseTorBridgeLine('  $spaced  ').line!.raw, spaced);
    });

    test('rejects an empty line', () {
      expect(parseTorBridgeLine('   ').error, TorBridgeParseError.empty);
      expect(parseTorBridgeLine('Bridge  ').error, TorBridgeParseError.empty);
    });

    test('rejects a transport we cannot run', () {
      // obfs3 is in tor's vocabulary and deprecated in Lyrebird; accepting
      // it would configure a plugin that never starts.
      expect(parseTorBridgeLine('obfs3 192.0.2.10:1 X').error,
          TorBridgeParseError.unknownTransport);
      expect(parseTorBridgeLine('nonsense 192.0.2.10:1').error,
          TorBridgeParseError.unknownTransport);
    });

    test('rejects a vanilla host:port with no transport', () {
      // Not obfs4 by assumption: a vanilla bridge needs UseBridges without a
      // ClientTransportPlugin, and guessing obfs4 here builds a config that
      // cannot work.
      expect(parseTorBridgeLine('192.0.2.10:9443').error,
          TorBridgeParseError.unknownTransport);
    });

    test('rejects a missing or malformed address', () {
      expect(parseTorBridgeLine('obfs4').error,
          TorBridgeParseError.malformedAddress);
      expect(parseTorBridgeLine('obfs4 192.0.2.10 cert=x').error,
          TorBridgeParseError.malformedAddress);
      expect(parseTorBridgeLine('obfs4 192.0.2.10: cert=x').error,
          TorBridgeParseError.malformedAddress);
    });

    test('accepts a bracketed IPv6 address', () {
      final r = parseTorBridgeLine('obfs4 [2001:db8::1]:9443 DEAD cert=x');
      expect(r.isOk, isTrue, reason: 'IPv6 bridges are ordinary');
    });

    test('names a missing obfs4 cert specifically', () {
      // Without cert= obfs4 cannot connect at all. Catching it here turns a
      // silent stall into an immediate explanation.
      expect(
        parseTorBridgeLine('obfs4 192.0.2.10:9443 DEADBEEF iat-mode=0').error,
        TorBridgeParseError.missingCertificate,
      );
    });

    test('snowflake needs no address of its own', () {
      final r = parseTorBridgeLine('snowflake 192.0.2.3:80 2B280B23E1107BB6');
      expect(r.isOk, isTrue);
      final bare = parseTorBridgeLine('snowflake');
      expect(bare.isOk, isTrue,
          reason: 'its rendezvous defaults are compiled in');
    });
  });

  group('torrc generation', () {
    TorBridgeLine line(String s) => parseTorBridgeLine(s).line!;

    test('emits plugin and bridge lines for the selected transport', () {
      final cfg = TorBridgeConfig(
        enabled: true,
        transport: TorTransport.obfs4,
        lines: [line(_obfs4)],
      );
      final opts = torBridgeOptions(cfg, transportPort: 47000);

      expect(opts, contains(('UseBridges', '1')));
      expect(
        opts,
        contains(('ClientTransportPlugin', 'obfs4 socks5 127.0.0.1:47000')),
      );
      expect(opts, contains(('Bridge', _obfs4)));
    });

    test('omits bridge lines belonging to another transport', () {
      // tor rejects a Bridge line whose transport has no plugin configured,
      // which fails the whole config rather than being ignored.
      final cfg = TorBridgeConfig(
        enabled: true,
        transport: TorTransport.snowflake,
        lines: [line(_obfs4), line('snowflake 192.0.2.3:80 2B280B23E110')],
      );
      final opts = torBridgeOptions(cfg, transportPort: 47000);

      expect(opts.where((o) => o.$1 == 'Bridge').length, 1);
      expect(opts.any((o) => o.$2.contains('obfs4')), isFalse);
    });

    test('produces nothing at all when disabled', () {
      final cfg = TorBridgeConfig(
        transport: TorTransport.obfs4,
        lines: [line(_obfs4)],
      );
      expect(torBridgeOptions(cfg, transportPort: 47000), isEmpty);
    });

    test('produces nothing rather than a half configuration', () {
      // UseBridges with nothing dialable is worse than no bridges: it stops
      // tor falling back to the direct guards that might have worked.
      final noLines = TorBridgeConfig(
        enabled: true,
        transport: TorTransport.obfs4,
      );
      expect(noLines.isUsable, isFalse);
      expect(torBridgeOptions(noLines, transportPort: 47000), isEmpty);

      final wrongTransport = TorBridgeConfig(
        enabled: true,
        transport: TorTransport.obfs4,
        lines: [line('snowflake')],
      );
      expect(torBridgeOptions(wrongTransport, transportPort: 47000), isEmpty);
    });

    test('snowflake is usable with no lines at all', () {
      const cfg = TorBridgeConfig(
        enabled: true,
        transport: TorTransport.snowflake,
      );
      expect(cfg.isUsable, isTrue);
      final opts = torBridgeOptions(cfg, transportPort: 47000);
      expect(opts, contains(('UseBridges', '1')));
      expect(opts.any((o) => o.$1 == 'Bridge'), isFalse);
    });

    test('produces nothing when the transport never got a port', () {
      // IPtProxy reports 0 when the transport failed to start; emitting a
      // plugin line pointing at port 0 would hang bootstrap instead of
      // failing loudly.
      final cfg = TorBridgeConfig(
        enabled: true,
        transport: TorTransport.obfs4,
        lines: [line(_obfs4)],
      );
      expect(torBridgeOptions(cfg, transportPort: 0), isEmpty);
    });
  });

  group('when bridges are offered', () {
    test('offered for the failures they can fix', () {
      expect(bridgesMayHelp(TorFailureKind.censored), isTrue);
      expect(bridgesMayHelp(TorFailureKind.bootstrapTimeout), isTrue);
    });

    test('not offered where they cannot help', () {
      // Sending someone with a wrong clock, a dead exit pin or a broken
      // control channel after bridges wastes their time on the one screen
      // that is supposed to tell them what to do.
      for (final k in const [
        TorFailureKind.clockSkew,
        TorFailureKind.exitPolicy,
        TorFailureKind.controlChannel,
        TorFailureKind.offline,
        TorFailureKind.runtime,
      ]) {
        expect(bridgesMayHelp(k), isFalse, reason: '$k');
      }
    });
  });
}
