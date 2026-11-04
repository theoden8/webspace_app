import 'dart:async';

import 'package:webspace/services/process_route.dart';

/// A webview leaving the process-wide rule, its quiet and its native destroy
/// each held until the test completes them; both at once when left null.
class FakeLeavingView implements LeavingView {
  FakeLeavingView({this.quietGate, this.destroyGate});

  final Completer<void>? quietGate;
  final Completer<void>? destroyGate;

  /// What has finished, in order: `quiet`, then `destroyed`.
  final List<String> done = [];

  @override
  Future<void> quiet() async {
    await quietGate?.future;
    done.add('quiet');
  }

  @override
  Future<void> destroyed() async {
    await destroyGate?.future;
    done.add('destroyed');
  }
}
