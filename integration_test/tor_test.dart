// The embedded Tor runtime, against the real plugin (TOR-018, TOR-019,
// TOR-020).
//
// Every other Tor test in this repo drives a fake `TorRuntime` that answers
// `TorUp` when told to, which is exactly why a control-port protocol bug and
// a process-singleton crash both shipped: nothing ever ran the handshake.
// This file runs it. iOS has no integration tier, so the runtime under test
// is the macOS one, which exists for this file alone — a shipped macOS build
// has no Tor pod and no Tor channels (macos/Podfile, TOR-007).
//
// Two tiers of assertion, because one of them needs the Tor network and the
// other does not:
//
//   - The handshake, the bootstrap phase, tor's own log and a restart are
//     asserted always. They are what broke, and none of them needs tor to
//     finish bootstrapping: tor opens its control port and its SOCKS
//     listener before it has reached anything.
//   - Reaching `up` needs the network to allow tor out. It is asserted only
//     when WEBSPACE_TOR_NETWORK=1, which is CI opting into that dependency
//     (see the workflow step). Locally it degrades to a skip with the log
//     attached, so a developer on a censored network is not stuck.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_service.dart';

/// Whether this run is the one that opted into the real Tor network.
final bool torRequired = Platform.environment['WEBSPACE_TOR_NETWORK'] == '1';

/// Where the plugin is supposed to exist, so its absence is a failure rather
/// than a platform this file does not cover.
final bool isApple = defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Everything the runtime and tor itself said, for a failure message that
/// explains itself instead of naming a timeout.
String torTranscript() {
  final entries = LogService.instance.allEntriesMerged
      .where((e) => e.tag == 'Tor' || e.tag == 'TorLog')
      .map((e) => '[${e.tag}/${e.level.name}] ${e.message}')
      .toList();
  return entries.isEmpty
      ? '(the Tor log is empty, which means the plugin never spoke)'
      : entries.join('\n');
}

/// The detail of a control-channel failure, or null for anything else.
///
/// The distinction this file turns on: tor not reaching the network is the
/// run's environment, and tor not reaching its own control port is our bug.
/// They arrive as the same `TorErrored`, and treating them alike is how a
/// broken handshake passed as "no network here" (BUG-013).
String? controlChannelFailure(TorStatus status) {
  if (status is! TorErrored) return null;
  final failure = classifyTorFailure(status.message);
  return failure.kind == TorFailureKind.controlChannel ? status.message : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late StreamSubscription<TorStatus> sub;
  final seen = <TorStatus>[];

  /// Printed, not asserted: when this file reports nothing useful the log is
  /// all there is, and the first run of it in CI reported two ticks and "no
  /// tests were found" with no way to tell which branch each test took.
  void trace(String message) {
    // ignore: avoid_print
    print('[tor-test] $message');
  }

  setUpAll(() {
    DeveloperModeService.instance.debugSet(true);
    sub = TorService.instance.statusStream.listen(seen.add);
    trace('platform=$defaultTargetPlatform '
        'available=${TorService.instance.isAvailable} '
        'torRequired=$torRequired '
        'env=${Platform.environment['WEBSPACE_TOR_NETWORK']}');
  });

  tearDownAll(() async {
    await sub.cancel();
    TorService.instance.release('integration');
    DeveloperModeService.instance.debugSet(false);
  });

  /// Poll until [done] or [budget] runs out. A plain `await for` on the
  /// status stream would hang past the test timeout when nothing arrives at
  /// all, which is the failure this file most wants to describe.
  Future<bool> waitFor(bool Function() done, Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (done()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return done();
  }

  testWidgets('the runtime bootstraps, says what it is doing, and restarts',
      (tester) async {
    trace('scenario 1 start');
    if (!TorService.instance.isAvailable) {
      // On an Apple build the runtime is supposed to be there, so its
      // absence is the finding rather than a reason to stand down: a skip
      // here is how a tier that reaches nothing reports success.
      if (isApple) {
        fail('the Tor runtime reports unavailable on an Apple build: either '
            'the plugin is not registered or developer mode did not take');
      }
      // Android, Linux and the web have no plugin (TOR-007); this file is
      // driven by the macOS tier.
      expect(torRequired, isFalse,
          reason: 'WEBSPACE_TOR_NETWORK=1 asked for a Tor run on a platform '
              'that has no runtime');
      markTestSkipped('no Tor runtime on this platform (TOR-007)');
      return;
    }

    await TorService.instance.maybeStart('integration');

    // The plugin answering at all. A build where it never registered lands
    // here as an error naming the missing runtime rather than as a hang.
    final spoke = await waitFor(
      () => TorService.instance.status is! TorStopped &&
          TorService.instance.status is! TorStarting,
      const Duration(seconds: 30),
    );
    final status = TorService.instance.status;
    expect(status is TorErrored && status.message.contains('No Tor runtime'),
        isFalse,
        reason: 'the channels have no plugin behind them: this build linked '
            'no tor, or the plugin was never registered');
    expect(spoke, isTrue,
        reason: 'the plugin never left "starting", so the control-port '
            'handshake did not complete:\n${torTranscript()}');
    // Leaving "starting" for an error is not completing the handshake. The
    // wait above is satisfied by either, so the failure that this file was
    // written for would otherwise travel on to the network assertions and
    // be reported as a network problem, or skipped outright.
    expect(controlChannelFailure(status), isNull,
        reason: 'the plugin never reached tor over its control port:\n'
            '${torTranscript()}');

    // TOR-018: the phase, not just a percentage. Before the fix TAG and
    // SUMMARY were read off the event and dropped at the platform seam, so
    // every bootstrapping status carried a bare number.
    final phased = await waitFor(
      () => seen.any((s) => s is TorBootstrapping && s.summary != null),
      const Duration(seconds: 30),
    );
    expect(phased, isTrue,
        reason: 'no bootstrap status carried tor\'s own phase:\n'
            '${seen.join(", ")}\n${torTranscript()}');

    // TOR-018: tor's own output reaches the app log, under its own tag and
    // in the sensitive ring.
    expect(
      LogService.instance.sensitiveEntries.where((e) => e.tag == 'TorLog'),
      isNotEmpty,
      reason: 'tor said nothing the app could show:\n${torTranscript()}',
    );
    expect(
      LogService.instance.entries.where((e) => e.tag == 'Tor'),
      isNotEmpty,
      reason: 'no state transition reached the app log',
    );

    // TOR-019: reaching `up` at all. The engine gives bootstrap 90 seconds
    // before it calls it off, so this waits a little past that to see which
    // of the two happened.
    final settled = await waitFor(
      () => TorService.instance.status is TorUp ||
          TorService.instance.status is TorErrored,
      const Duration(seconds: 100),
    );
    expect(settled, isTrue,
        reason: 'bootstrap neither finished nor failed:\n${torTranscript()}');

    final outcome = TorService.instance.status;
    if (outcome is TorUp) {
      expect(TorService.instance.socksEndpoint, isNotNull);
      expect(TorService.instance.socksFor(siteId: 'site-1'), isNotNull,
          reason: 'a connected runtime must hand a site its SOCKS settings');
    } else if (controlChannelFailure(outcome) != null) {
      // Never a skip, on any run: nothing here depends on the network.
      fail('Tor never answered on its control port:\n${torTranscript()}');
    } else if (torRequired) {
      fail('Tor did not connect on a run that required it:\n'
          '${torTranscript()}');
    } else {
      markTestSkipped('Tor did not reach the network here; '
          'handshake assertions still ran');
    }

    // TOR-020: a restart is the Retry button, and it must not stop tor. The
    // process gets one `tor_run_main`: the second dies in `threadpool_new`
    // and never bootstraps, so a Retry that tore the runtime down would end
    // the feature for the session (BUG-013 attempt 9). Retry re-arms the
    // wait on the tor that is already there.
    final before = TorService.instance.socksEndpoint;
    await TorService.instance.restart();
    final restarted = await waitFor(
      () => TorService.instance.status is TorUp ||
          TorService.instance.status is TorBootstrapping ||
          TorService.instance.status is TorErrored,
      const Duration(seconds: 60),
    );
    expect(restarted, isTrue,
        reason: 'the runtime never reported after a restart:\n'
            '${torTranscript()}');
    expect(TorService.instance.status, isNot(isA<TorStopped>()));
    expect(controlChannelFailure(TorService.instance.status), isNull,
        reason: 'the restarted runtime never reached tor\'s control port:\n'
            '${torTranscript()}');
    if (before != null) {
      expect(TorService.instance.socksEndpoint, before,
          reason: 'a Retry replaced the running tor instead of waiting on '
              'it; this process has no second launch:\n${torTranscript()}');
    }
    expect(
      LogService.instance.allEntriesMerged
          .any((e) => e.message.contains('already run once')),
      isFalse,
      reason: 'a Retry tried to launch a second tor:\n${torTranscript()}',
    );
    trace('scenario 1 done');
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('repeated Retries never take the runtime down', (tester) async {
    trace('scenario 2 start');
    if (!TorService.instance.isAvailable) {
      if (isApple) {
        fail('the Tor runtime reports unavailable on an Apple build');
      }
      markTestSkipped('no Tor runtime on this platform (TOR-007)');
      return;
    }

    // Retry is the one control the failure interstitial offers, and a user
    // whose first bootstrap is slow will use it more than once. Each one
    // used to stop and re-start tor; the second launch dies in
    // `threadpool_new` and never bootstraps, so two taps were enough to end
    // Tor for the session (BUG-013 attempt 9, TOR-020). Three taps here,
    // back to back, including one inside a handshake window.
    await TorService.instance.restart();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await TorService.instance.restart();
    await TorService.instance.restart();

    final recovered = await waitFor(
      () => TorService.instance.status is TorBootstrapping ||
          TorService.instance.status is TorUp,
      const Duration(seconds: 90),
    );
    expect(recovered, isTrue,
        reason: 'the runtime did not survive repeated Retries:'
            '\n${torTranscript()}');
    expect(
      LogService.instance.allEntriesMerged
          .any((e) => e.message.contains('already run once')),
      isFalse,
      reason: 'a Retry tried to launch a second tor:\n${torTranscript()}',
    );
    expect(
      LogService.instance.allEntriesMerged
          .any((e) => e.message.contains('still running')),
      isFalse,
      reason: 'a previous tor was left holding the process:\n'
          '${torTranscript()}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
