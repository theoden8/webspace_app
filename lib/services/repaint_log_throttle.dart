/// Pure-Dart burst collapser for the `SurfaceDiag` repaint trace.
///
/// Every surface repaint reports which path asked for it, which is what makes
/// a blank-screen report diagnosable at all (BUG-001). But repaints come in
/// bursts by design — `didChangeMetrics` fires repeatedly through a warm
/// resume, and the nudge funnel coalesces concurrent callers — so a line per
/// call would evict the rest of `LogService`'s 2000-entry ring with the same
/// sentence repeated. This keeps the first of a burst and folds the rest into
/// one summary, so the trace stays readable and stays bounded.
///
/// The host supplies the clock and the flush timer; this class never imports
/// Flutter. See test/repaint_log_throttle_test.dart.
library;

class RepaintLogThrottle {
  /// A repeat of the same trigger within this window folds into the summary
  /// rather than emitting its own line. Long enough to swallow a metrics
  /// burst or a coalescing storm, short enough that two genuinely separate
  /// user actions on the same trigger still read as two events.
  static const Duration burstWindow = Duration(seconds: 2);

  String? _trigger;
  DateTime? _firstAt;
  int _folded = 0;
  int _coalesced = 0;

  /// Whether a folded burst is waiting to be summarised. The host arms its
  /// flush timer on this.
  bool get hasPending => _folded > 0;

  /// Record one repaint request. Returns the lines the host should log, in
  /// order — 0, 1 or 2 of them: a burst that ends because a *different*
  /// trigger arrived emits its summary before the new trigger's line.
  ///
  /// [coalesced] means an already-running tick loop absorbed the request. The
  /// repaint still happens; it is counted rather than announced, because a
  /// coalescing storm is the noisiest case and the least informative.
  List<String> note(String trigger,
      {required bool coalesced, required DateTime now}) {
    final continues = trigger == _trigger &&
        _firstAt != null &&
        now.difference(_firstAt!) < burstWindow;
    if (continues) {
      _folded++;
      if (coalesced) _coalesced++;
      return const [];
    }
    final lines = <String>[];
    final summary = flush();
    if (summary != null) lines.add(summary);
    _trigger = trigger;
    _firstAt = now;
    _folded = 0;
    _coalesced = coalesced ? 1 : 0;
    lines.add('trigger=$trigger -> nudge${coalesced ? ' (coalesced)' : ''}');
    return lines;
  }

  /// Emit the pending burst summary, or null when there is nothing folded.
  /// Called by the host's flush timer and before a differing trigger's line.
  String? flush() {
    if (_folded == 0) {
      _coalesced = 0;
      return null;
    }
    final n = _folded;
    final coalesced = _coalesced;
    _folded = 0;
    _coalesced = 0;
    final trigger = _trigger;
    // Keep the trigger armed but restart its window, so a burst that outlives
    // one flush reports as successive summaries rather than one unbounded run.
    _firstAt = null;
    return 'trigger=$trigger -> nudge x$n more'
        '${coalesced > 0 ? ' ($coalesced coalesced)' : ''}';
  }
}
