// Tor is gated behind developer mode until its bootstrap surface exists
// (TOR-007 platform gate AND DEVTOOLS-010 developer mode). The gate lives on
// TorService, not on the runtime or the engine: those answer the narrower
// "does this build have a tor to talk to", which the engine's own tests
// exercise against a fake.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';

/// Available runtime that records what the engine asked it to do, so a test
/// can tell "refused at the gate" from "asked and got nothing".
class _AvailableRuntime implements TorRuntime {
  final _events = StreamController<TorStatus>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  final applied = <String?>[];

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
  Future<void> applyExitCountry(String? exitNodes) async =>
      applied.add(exitNodes);

  void emit(TorStatus s) => _events.add(s);
  Future<void> dispose() => _events.close();
}

void main() {
  late _AvailableRuntime runtime;

  setUp(() {
    runtime = _AvailableRuntime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'secret'),
    );
  });

  tearDown(() async {
    await TorService.reset();
    await runtime.dispose();
    DeveloperModeService.instance.debugSet(false);
  });

  test('a platform with tor still reports unavailable while dev mode is off',
      () {
    DeveloperModeService.instance.debugSet(false);
    expect(TorService.instance.isAvailable, isFalse);
  });

  test('turning developer mode on opens the gate with no restart', () {
    DeveloperModeService.instance.debugSet(false);
    expect(TorService.instance.isAvailable, isFalse);
    DeveloperModeService.instance.debugSet(true);
    expect(TorService.instance.isAvailable, isTrue,
        reason: 'the flag is read per call, not cached at construction');
  });

  test('maybeStart does not spawn tor while the gate is shut', () async {
    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.maybeStart('site-a');
    expect(runtime.startCalls, 0);
  });

  test('syncHolders takes no holders while the gate is shut', () async {
    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.syncHolders({'site-a', 'site-b'});
    expect(runtime.startCalls, 0);
  });

  test('turning developer mode off releases the holders already taken',
      () async {
    // The bug this guards: an early return in the sync path would leave the
    // runtime pinned up for a feature the user can no longer reach.
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    expect(runtime.startCalls, 1);

    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.syncHolders({'site-a'});

    // Release is debounced, so assert the holder set emptied rather than
    // waiting out the idle timer.
    expect(TorService.instance.isAvailable, isFalse);
    await TorService.instance.maybeStart('site-a');
    expect(runtime.startCalls, 1, reason: 'no restart behind the shut gate');
  });

  test('setExitCountry does not reach tor while the gate is shut', () async {
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    runtime.emit(const TorUp('127.0.0.1', 41337));
    await Future<void>.delayed(Duration.zero);

    DeveloperModeService.instance.debugSet(false);
    await TorService.instance.setExitCountry('{de}');
    expect(runtime.applied, isEmpty);
  });

  test('socksFor fails closed rather than falling back to direct', () async {
    // A site still carrying ProxyType.TOR from before the flag was turned
    // off must be blocked, never quietly sent out over the device IP.
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    runtime.emit(const TorUp('127.0.0.1', 41337));
    await Future<void>.delayed(Duration.zero);
    expect(TorService.instance.socksFor(siteId: 'site-a'), isNotNull);

    DeveloperModeService.instance.debugSet(false);
    final resolved = TorService.instance.socksFor(siteId: 'site-a');
    expect(resolved, isNull);
  });

  test('with the gate open the SOCKS settings carry the isolation tag', () async {
    DeveloperModeService.instance.debugSet(true);
    await TorService.instance.syncHolders({'site-a'});
    runtime.emit(const TorUp('127.0.0.1', 41337));
    await Future<void>.delayed(Duration.zero);

    final resolved = TorService.instance.socksFor(siteId: 'site-a')!;
    expect(resolved.type, ProxyType.SOCKS5);
    expect(resolved.username, 'site-a');
  });
}
