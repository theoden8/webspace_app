import 'dart:async';

import 'package:webspace/services/tor_engine.dart';

/// [TorRuntime] that records every call and lets a test play the native
/// side: [emit] pushes a status as the event channel would.
class FakeTorRuntime implements TorRuntime {
  FakeTorRuntime({this.isAvailable = true, this.onStart});

  /// Settable so a test can be the platform that ships no Tor (TOR-022).
  @override
  final bool isAvailable;

  /// Runs inside [start], after the call is counted and [startError] checked.
  final void Function(FakeTorRuntime runtime)? onStart;

  final _events = StreamController<TorStatus>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  int rebuildCalls = 0;
  Object? startError;

  /// Every [applyExitCountry] that reached the runtime, answered or not.
  int applyCalls = 0;
  final appliedExitNodes = <String?>[];
  final appliedGeoIpFiles = <String?>[];
  Object? exitCountryError;

  /// Models a control connection that dropped: the call never returns.
  bool exitCountryHangs = false;

  int transportPort = 47000;
  final startedTransports = <String>[];
  List<(String, String)> torrcOptions = const [];
  Object? transportError;

  int reopenCalls = 0;
  int reopenPort = 45000;
  Object? reopenError;

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

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {
    torrcOptions = options;
  }

  /// Models the plugin: a fresh listener, published as `up` on its own port.
  @override
  Future<void> reopenListeners() async {
    reopenCalls++;
    if (reopenError != null) throw reopenError!;
    emit(TorUp('127.0.0.1', port: reopenPort));
  }

  Future<void> dispose() => _events.close();
}
