/// Cold-start initialization policy, extracted so the orchestration can be
/// unit-tested with fakes (see test/startup_init_engine_test.dart) instead of
/// being buried in `main()`. No Flutter imports, no platform channels — the
/// engine only sequences callbacks; the real service inits live at the call
/// site in main.dart.
typedef AsyncStep = Future<void> Function();

class StartupInitEngine {
  /// Runs [bridgeSetup] (synchronous: some [independentInits] push into the
  /// native interceptor bridge while initializing, so it must exist first),
  /// then runs every entry in [independentInits] concurrently and completes
  /// when all have finished.
  ///
  /// The inits touch disjoint storage and feed independent subsystems, so
  /// wall-clock stays at ~max(step) instead of sum(step) — the heavy
  /// adblock-engine/DNS/dataset loads no longer serialize on the cold-launch
  /// critical path. All still complete before this future resolves (the caller
  /// awaits it before runApp), so the fail-closed blocking posture is
  /// unchanged.
  static Future<void> runIndependentInits(
    List<AsyncStep> independentInits, {
    void Function()? bridgeSetup,
  }) async {
    bridgeSetup?.call();
    await Future.wait([for (final init in independentInits) init()]);
  }
}
