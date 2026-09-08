// Refcount lifecycle of the interstitial that stands in for a TOR-bound
// webview (TOR-008 fail-closed).
//
// What each state *renders* is asserted in tor_ui_states_test.dart, which
// covers every failure kind with its copy and remedy. This file keeps the
// part that file does not: that merely showing the placeholder is enough to
// get the runtime started, and that it lets go again on the way out.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/widgets/tor_bootstrap.dart';

class _Runtime implements TorRuntime {
  final _events = StreamController<TorStatus>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  Stream<TorStatus> get events => _events.stream;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> rebuildCircuits() async {}

  @override
  Future<void> applyExitCountry(String? exitNodes) async {}

  void emit(TorStatus s) => _events.add(s);
}

void main() {
  /// Install a fake-backed engine **from inside the test body**.
  ///
  /// Not from `setUp`: that runs in the real async zone, while a
  /// `testWidgets` body runs inside `fakeAsync`. `TorEngine`'s constructor
  /// subscribes to `runtime.events`, and a stream delivers to its listener
  /// in the zone that called `listen`. Built in `setUp`, the engine's
  /// `_onRuntimeStatus` deliveries are scheduled on the real microtask
  /// queue, which `tester.pump` never drains — so `runtime.emit(...)`
  /// silently never reaches the engine.
  _Runtime installEngine() {
    final runtime = _Runtime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'secret'),
    );
    // The widget calls TorService.maybeStart, whose refcount-take is gated
    // on isAvailable. Turn dev mode on so the acquire actually reaches the
    // fake runtime — otherwise startCalls stays 0 and the widget looks
    // broken for the wrong reason.
    DeveloperModeService.instance.debugSet(true);
    return runtime;
  }

  tearDown(() async {
    await TorService.reset();
    DeveloperModeService.instance.debugSet(false);
  });

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
  }

  Widget host(Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      );

  testWidgets('showing the placeholder is enough to start the runtime',
      (t) async {
    final runtime = installEngine();
    expect(runtime.startCalls, 0);

    await t.pumpWidget(host(const TorBootstrapPlaceholder()));
    await settle(t);

    expect(runtime.startCalls, 1,
        reason: 'the placeholder acquires a refcount so bootstrap actually '
            'begins even if no site is holding one yet');

    // Unmount, then run the engine's two one-shot timers out on the fake
    // clock: `acquire` arms a 90s bootstrap timeout and `release` a 60s
    // idle debounce, and flutter_test fails a test that ends with a pending
    // Timer. The group tearDown cannot clear them — it runs after the
    // binding's invariant check — and awaiting TorService.reset() here
    // deadlocks, because the await stops the body from advancing the very
    // clock the disposal waits on.
    await t.pumpWidget(const SizedBox.shrink());
    await settle(t);
    await t.pump(const Duration(seconds: 91));

    // Released rather than re-acquired on the way out: no second start, and
    // the idle debounce was allowed to expire into a stop.
    expect(runtime.startCalls, 1);
    expect(runtime.stopCalls, greaterThan(0),
        reason: 'the last holder going away must let the runtime shut down');
  });
}
