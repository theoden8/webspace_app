// TOR-015: Tor fails in kinds, not in strings.
//
// Each branch of the classifier decides what the user is told and what
// remedy they are offered, so each gets a case here. The ordering cases
// matter as much as the positive ones: several signatures overlap, and the
// wrong precedence tells a user with a wrong clock that they are censored.

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/tor_failure.dart';

void main() {
  group('classifyTorFailure', () {
    test('clock skew wins over the circuit wording it shares', () {
      // tor's clock-skew warning also talks about circuits, which is the
      // censored/exit-policy vocabulary too.
      final f = classifyTorFailure(
        'Clock skew of 3600 seconds detected; tor will not build circuits.',
      );
      expect(f.kind, TorFailureKind.clockSkew);
    });

    test('control-channel failures are ours, never reported as censorship',
        () {
      for (final m in const [
        'Tor did not publish a control port.',
        'Could not reach the Tor control port: connection refused',
        'Tor control cookie unreadable.',
        'Tor control authentication failed: bad cookie',
        'Tor reported no usable SOCKS listener.',
      ]) {
        expect(classifyTorFailure(m).kind, TorFailureKind.controlChannel,
            reason: '"$m" is a defect on our side of the channel');
      }
    });

    test('an exit pin that would not apply is an exitPolicy failure', () {
      final f = classifyTorFailure('Could not apply the exit-country pin: x',
          hadExitPin: true);
      expect(f.kind, TorFailureKind.exitPolicy);
    });

    test('a strict pin stalling late is the pin, not the network', () {
      // StrictNodes makes an unusable exit country fatal, and it fails
      // where circuits are built rather than where directories are fetched.
      final f = classifyTorFailure(
        'Tor did not finish bootstrapping in time.',
        atPercent: 90,
        torTag: 'circuit_create',
        hadExitPin: true,
        timedOut: true,
      );
      expect(f.kind, TorFailureKind.exitPolicy);
    });

    test('tor NOROUTE means offline, not censored', () {
      final f = classifyTorFailure('bootstrap stalled',
          torReason: 'NOROUTE', atPercent: 5, timedOut: true);
      expect(f.kind, TorFailureKind.offline);
    });

    test('a refused or reset connection is the censorship signature', () {
      for (final r in const ['CONNECTREFUSED', 'CONNECTRESET', 'IDENTITY']) {
        final f = classifyTorFailure('bootstrap stalled',
            torReason: r, atPercent: 10, timedOut: true);
        expect(f.kind, TorFailureKind.censored, reason: 'REASON=$r');
      }
    });

    test('a timeout stalled in the directory phase reads as censored', () {
      final f = classifyTorFailure(
        'Tor did not finish bootstrapping in time.',
        atPercent: 10,
        torTag: 'conn_dir',
        timedOut: true,
      );
      expect(f.kind, TorFailureKind.censored);
    });

    test('a timeout past the directory phase is just a timeout', () {
      // No pin, got a long way, no tor reason: nothing points at a cause,
      // and guessing "censored" here would send the user after bridges for
      // a slow network.
      final f = classifyTorFailure(
        'Tor did not finish bootstrapping in time.',
        atPercent: 95,
        torTag: 'circuit_create',
        timedOut: true,
      );
      expect(f.kind, TorFailureKind.bootstrapTimeout);
    });

    test('an unrecognised message degrades to runtime, not to a guess', () {
      final f = classifyTorFailure('the tor thread exited unexpectedly');
      expect(f.kind, TorFailureKind.runtime);
      expect(f.detail, 'the tor thread exited unexpectedly');
    });

    test('tor RECOMMENDATION=ignore marks a failure transient', () {
      final f = classifyTorFailure('bootstrap stalled',
          torReason: 'TIMEOUT', recommendation: 'ignore', timedOut: true);
      expect(f.isTransient, isTrue,
          reason: 'tor expects to recover; not a hard failure to shout about');
      final hard = classifyTorFailure('bootstrap stalled',
          torReason: 'TIMEOUT', recommendation: 'warn', timedOut: true);
      expect(hard.isTransient, isFalse);
    });

    test('the raw signals survive classification for a bug report', () {
      final f = classifyTorFailure(
        'Tor did not finish bootstrapping in time.',
        torTag: 'handshake_dir',
        torReason: 'TIMEOUT',
        recommendation: 'warn',
        atPercent: 25,
        timedOut: true,
      );
      expect(f.detail, contains('bootstrapping'));
      expect(f.torTag, 'handshake_dir');
      expect(f.torReason, 'TIMEOUT');
      expect(f.atPercent, 25);
      expect(f.toString(), contains('tag=handshake_dir'));
      expect(f.toString(), contains('at=25%'));
    });
  });
}
