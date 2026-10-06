/// Re-entry guard for an async handler that can be entered again before its
/// first call resolves: a double tap, a lifecycle event firing twice. [run]
/// owns the `finally` that releases it, so no exit path leaves it held.
class ReentryGuard {
  bool _busy = false;

  bool get busy => _busy;

  /// Runs [body] unless a run is in flight. Returns false when it skipped.
  Future<bool> run(Future<void> Function() body) async {
    if (_busy) return false;
    _busy = true;
    try {
      await body();
    } finally {
      _busy = false;
      onReleased();
    }
    return true;
  }

  /// Called after every release.
  void onReleased() {}
}
