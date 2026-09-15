// A webview's Tor binding is frozen at construction, so the app has to know
// when that binding went stale (TOR-008).
//
// Reported from a device: "sometimes I have to restart the app for the Tor
// proxy to start working". A restart of the runtime comes back on a fresh
// loopback port -- tor asks the OS for one -- and the rule that decided
// whether to rebuild webviews compared `isUp` on both sides. Up to Up reads
// as no change however far the port moved, and a webview still bound to the
// old one reaches nothing, with TOR-008 correctly refusing to fall back to
// direct. Restarting the app was the only way out.

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/tor_engine.dart';

void main() {
  group('torBindingChanged', () {
    test('a restart on a new port is a change, even though both are up', () {
      expect(
        torBindingChanged(const TorUp('127.0.0.1', 50496),
            const TorUp('127.0.0.1', 50818)),
        isTrue,
      );
    });

    test('the same endpoint twice is not', () {
      expect(
        torBindingChanged(const TorUp('127.0.0.1', 9050),
            const TorUp('127.0.0.1', 9050)),
        isFalse,
      );
    });

    test('coming up and going away are both changes', () {
      expect(
        torBindingChanged(const TorStopped(), const TorUp('127.0.0.1', 9050)),
        isTrue,
      );
      expect(
        torBindingChanged(const TorUp('127.0.0.1', 9050), const TorStopped()),
        isTrue,
      );
    });

    test('states with nothing to bind to do not churn webviews', () {
      // Every one of these resolves to "no endpoint", so moving between them
      // must not dispose a thing: the sites are on the interstitial already.
      final unbound = <TorStatus>[
        const TorStopped(),
        const TorStarting(),
        const TorBootstrapping(40),
        TorErrored('Could not reach the Tor control port'),
      ];
      for (final a in unbound) {
        for (final b in unbound) {
          expect(torBindingChanged(a, b), isFalse, reason: '$a -> $b');
        }
      }
    });

    test('a host change counts, not just a port change', () {
      expect(
        torBindingChanged(
            const TorUp('127.0.0.1', 9050), const TorUp('127.0.0.2', 9050)),
        isTrue,
      );
    });
  });
}
