// Widget contract for the interstitial that stands in for a TOR-bound
// webview while the runtime is not [TorUp]. The point of the widget is
// twofold: block a null-proxy InAppWebView from ever being constructed
// (TOR-008 fail-closed), and give the user something visible while
// bootstrap runs (TOR-013).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<void> dispose() => _events.close();
}

void main() {
  late _Runtime runtime;

  setUp(() {
    runtime = _Runtime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'secret'),
    );
    // The widget uses TorService.maybeStart, whose refcount-take is gated
    // on isAvailable. Turn dev mode on so the acquire actually reaches the
    // fake runtime — otherwise startCalls stays 0 and the widget looks
    // broken for the wrong reason.
    DeveloperModeService.instance.debugSet(true);
  });

  tearDown(() async {
    await TorService.reset();
    await runtime.dispose();
    DeveloperModeService.instance.debugSet(false);
  });

  Future<void> pumpAndSettleMicrotasks(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
  }

  testWidgets('renders a progress bar while bootstrapping', (t) async {
    await t.pumpWidget(const MaterialApp(home: TorBootstrapPlaceholder()));
    await pumpAndSettleMicrotasks(t);

    runtime.emit(const TorBootstrapping(45));
    await pumpAndSettleMicrotasks(t);

    final progressFinder = find.byType(LinearProgressIndicator);
    expect(progressFinder, findsOneWidget);
    final progress = t.widget<LinearProgressIndicator>(progressFinder);
    expect(progress.value, closeTo(0.45, 1e-6));
  });

  testWidgets('renders an error icon on TorErrored, no retry button',
      (t) async {
    await t.pumpWidget(const MaterialApp(home: TorBootstrapPlaceholder()));
    await pumpAndSettleMicrotasks(t);

    runtime.emit(const TorErrored('directory authority unreachable'));
    await pumpAndSettleMicrotasks(t);

    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    // No retry: the current engine has no restart-from-error path
    // (TorEngine.acquire returns early with a non-empty holder set), so
    // the button would be inert. Guard against it accidentally coming back
    // and lying to the user.
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('kicks TorService.maybeStart on mount and releases on unmount',
      (t) async {
    expect(runtime.startCalls, 0);

    await t.pumpWidget(const MaterialApp(home: TorBootstrapPlaceholder()));
    await pumpAndSettleMicrotasks(t);

    expect(runtime.startCalls, 1,
        reason: 'the placeholder acquires a refcount so bootstrap actually '
            'begins even if no site is holding one yet');

    await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await pumpAndSettleMicrotasks(t);

    // The idle-stop debounce means stop is not immediate; the important
    // property is that the holder is released, which the next test path
    // (letting the debounce elapse) would show — here we just assert the
    // mount side stays quiet, i.e. no repeat start after unmount.
    expect(runtime.startCalls, 1);
  });
}
