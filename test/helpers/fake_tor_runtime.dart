import 'dart:async';

import 'package:webspace/services/tor_engine.dart';

/// [TorRuntime] that records every call and lets a test play the native
/// side: [emit] pushes a status as the event channel would.
///
/// The failures it can be told to raise are the ones [TorRuntime] declares:
/// [TorRuntimeFailure], and for [applyExitCountry] the exit-pin refusals.
class FakeTorRuntime implements TorRuntime {
  FakeTorRuntime({
    this.isAvailable = true,
    this.retriesFreely = false,
    this.onStart,
  });

  /// Settable so a test can be the platform that ships no Tor (TOR-022).
  @override
  final bool isAvailable;

  /// True to play an external tor, whose start is a probe (TOR-025).
  @override
  final bool retriesFreely;

  /// Runs inside [start], after the call is counted and [startError] checked.
  final void Function(FakeTorRuntime runtime)? onStart;

  final _events = StreamController<TorStatus>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  int rebuildCalls = 0;
  TorRuntimeFailure? startError;

  /// Every [applyExitCountry] that reached the runtime, answered or not.
  int applyCalls = 0;
  final appliedExitNodes = <String?>[];
  final appliedGeoIpFiles = <String?>[];

  /// A [TorRuntimeFailure], [TorExitCountryEmpty] or [TorExitPinUnsupported].
  Exception? exitCountryError;

  /// Models a control connection that dropped: the call never returns.
  bool exitCountryHangs = false;

  int transportPort = 47000;
  final startedTransports = <String>[];
  List<(String, String)> torrcOptions = const [];
  TorRuntimeFailure? transportError;

  /// Every [restartTransport], and the port the next one answers.
  final restartedTransports = <String>[];
  int restartPort = 47100;

  int reopenCalls = 0;
  int reopenPort = 45000;
  TorRuntimeFailure? reopenError;

  /// The bridge lines each [reopenListeners] put in force.
  final reopenBridgeOptions = <List<(String, String)>>[];

  /// What [circuitEstablished] answers; every ask is counted.
  bool circuit = true;
  int circuitAsks = 0;

  @override
  Stream<TorStatus> get events => _events.stream;

  void emit(TorStatus s) => _events.add(s);

  /// Drive a full successful bootstrap.
  void bootstrapTo(int port) {
    emit(const TorBootstrapping(10));
    emit(const TorBootstrapping(80));
    emit(TorUp('127.0.0.1', port: port));
  }

  @override
  Future<void> start() async {
    startCalls++;
    if (startError != null) throw startError!;
    onStart?.call(this);
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> rebuildCircuits() async => rebuildCalls++;

  @override
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile}) async {
    applyCalls++;
    if (exitCountryHangs) return Completer<void>().future;
    if (exitCountryError != null) throw exitCountryError!;
    appliedExitNodes.add(exitNodes);
    appliedGeoIpFiles.add(geoipFile);
  }

  @override
  Future<int> startTransport(String transport) async {
    if (transportError != null) throw transportError!;
    startedTransports.add(transport);
    return transportPort;
  }

  /// Models IPtProxy: a fresh listener on a fresh port.
  @override
  Future<int> restartTransport(String transport) async {
    if (transportError != null) throw transportError!;
    restartedTransports.add(transport);
    return restartPort;
  }

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {
    torrcOptions = options;
  }

  /// Models the plugin: a fresh listener, published as `up` on its own port.
  @override
  Future<void> reopenListeners(
      {required List<(String, String)> bridgeOptions}) async {
    reopenCalls++;
    if (reopenError != null) throw reopenError!;
    reopenBridgeOptions.add(bridgeOptions);
    emit(TorUp('127.0.0.1', port: reopenPort));
  }

  @override
  Future<bool> circuitEstablished() async {
    circuitAsks++;
    return circuit;
  }

  Future<void> dispose() => _events.close();
}
