/// Re-entry guard for an async handler that can be entered again before its
/// first call resolves: a double tap, a lifecycle event firing twice. [run]
/// owns the `finally` that releases it, so no exit path leaves it held.
final class ReentryGuard {
  /// [onChange] is told as a run starts and as it ends, so a widget that
  /// shows [busy] rebuilds on every exit:
  /// `ReentryGuard(onChange: () { if (mounted) setState(() {}); })`.
  ReentryGuard({this.onChange});

  final void Function()? onChange;
  bool _busy = false;

  bool get busy => _busy;

  /// Runs [body] unless a run is in flight. Returns false when it skipped.
  Future<bool> run(Future<void> Function() body) async {
    if (_busy) return false;
    _busy = true;
    onChange?.call();
    try {
      await body();
    } finally {
      _busy = false;
      onChange?.call();
    }
    return true;
  }
}
