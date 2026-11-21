import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/log_service.dart';

/// A phase of this process's launch. The line lists them in the order this
/// launch reached them; declaration order breaks a tie.
enum LaunchMark {
  dnsLoaded('dns loaded'),
  blockerLoaded('blocker loaded'),
  runApp('runApp'),
  prefsLoaded('prefs'),
  shellLoaded('shell'),
  isolationProbed('isolation'),
  sitesLoaded('sites loaded'),
  firstBuild('first build'),
  firstFrame('first frame'),
  sitesOnPage('sites on page'),
  shortcutsPruned('shortcuts pruned'),
  launchTarget('launch target'),
  routes('routes'),
  activated('site activated'),
  webViewBuilt('webview built'),
  pageStarted('page started'),
  pageSettled('page settled');

  const LaunchMark(this.label);

  final String label;
}

/// The five phases a user-visible activation moves through, from the tap to
/// the page settling. A switch (site, tab or webspace) times them from its
/// tap; the launch times them from `main()`, after its startup marks. They are
/// a subset of [LaunchMark], so there is one set of phase names, not two.
const List<LaunchMark> _switchPhases = [
  LaunchMark.activated,
  LaunchMark.webViewBuilt,
  LaunchMark.pageStarted,
  LaunchMark.pageSettled,
];

/// The originating step of a user-visible switch (a site, a tab or a
/// webspace), which opens a switch segment. A trend tool (DEVTOOLS-013): the
/// set is the switches worth timing, not every flow, so a step left out means
/// that switch is not timed, never a wrong number. An off-screen flow
/// (`preload`, `wake`, `background`) opens no segment.
const Set<ActivationStep> _switchOrigins = {
  ActivationStep.tap,
  ActivationStep.spaceSwitch,
  ActivationStep.nestedOpen,
  ActivationStep.openTab,
  ActivationStep.newTab,
  ActivationStep.duplicateTab,
  ActivationStep.childTab,
  ActivationStep.reopenTab,
};

/// The step mark a switch reads for its [LaunchMark.activated] phase: the
/// model commit that applies the switch. The other phases come from the same
/// `reached` calls the launch uses (the webview's build and loads).
const ActivationStep _activatedStep = ActivationStep.commit;

/// One timed activation: the launch, or a later switch. Each phase's time is
/// milliseconds from the segment's start (`main()` for the launch, the tap for
/// a switch), recorded once.
class _Segment {
  _Segment(this._startMs);

  final int _startMs;
  final Map<LaunchMark, int> _phases = {};

  void reached(LaunchMark mark, {required int at}) =>
      _phases.putIfAbsent(mark, () => at - _startMs);

  bool get isEmpty => _phases.isEmpty;

  /// The phases in the order they were reached; declaration order breaks a tie.
  String get line {
    final reached = _phases.entries.toList()
      ..sort((a, b) => a.value != b.value
          ? a.value.compareTo(b.value)
          : a.key.index.compareTo(b.key.index));
    return [for (final e in reached) '${e.key.label} ${e.value}ms'].join(', ');
  }
}

/// The activation timeline, kept in memory and written as App Logs lines
/// (DEVTOOLS-013): the launch, timed from `main()` and reported when the
/// launched page settles or stops being waited for, and every later
/// user-visible switch (site, tab or webspace), timed from its tap and
/// reported when its page settles or the next switch supersedes it. A line
/// names no site and is not sensitive, so an activation can be timed on a
/// device with no debugger attached, and nothing it keeps is persisted, so an
/// archive-tier site varies no stored state through it (ARCH-001).
abstract final class LaunchTimeline {
  static final Stopwatch _clock = Stopwatch();
  static final Map<LaunchMark, int> _at = {};
  static final Map<ActivationStep, int> _steps = {};
  static bool _ended = false;

  /// The switch being timed now, after the launch has ended; null until one
  /// begins, replaced when the next does (the previous one emitted first).
  static _Segment? _switch;

  /// main() starts the clock before anything else.
  static void start() => _clock.start();

  @visibleForTesting
  static void resetForTest() {
    _clock
      ..stop()
      ..reset();
    _at.clear();
    _steps.clear();
    _switch = null;
    _ended = false;
  }

  /// Notes the first time [mark] is reached. Before the launch ends it is the
  /// launch's; after, it is the switch being timed, which the launch's own
  /// `reached` calls (the webview's build and loads) now feed too. A
  /// [LaunchMark.pageSettled] ends the switch's segment.
  static void reached(LaunchMark mark) {
    if (!_clock.isRunning) return;
    if (!_ended) {
      _at.putIfAbsent(mark, () => _clock.elapsedMilliseconds);
      return;
    }
    if (!_switchPhases.contains(mark)) return;
    _switch?.reached(mark, at: _clock.elapsedMilliseconds);
    if (mark == LaunchMark.pageSettled) _emitSwitch();
  }

  /// Notes an activation step. Before the launch ends it records the first
  /// time the launch marked each step. After, an originating step opens a new
  /// switch segment (emitting the previous one first), and the commit step is
  /// the switch's `activated` phase. main() hands this to
  /// [ActivationSteps.sink].
  static void stepReached(ActivationStep step) {
    if (!_clock.isRunning) return;
    if (!_ended) {
      _steps.putIfAbsent(step, () => _clock.elapsedMilliseconds);
      return;
    }
    if (_switchOrigins.contains(step)) {
      _emitSwitch();
      _switch = _Segment(_clock.elapsedMilliseconds);
      return;
    }
    if (step == _activatedStep) {
      _switch?.reached(LaunchMark.activated, at: _clock.elapsedMilliseconds);
    }
  }

  static String _inOrder<T extends Enum>(Map<T, int> at,
      {required String Function(T) label}) {
    final reached = at.entries.toList()
      ..sort((a, b) => a.value != b.value
          ? a.value.compareTo(b.value)
          : a.key.index.compareTo(b.key.index));
    return [for (final e in reached) '${label(e.key)} ${e.value}ms'].join(', ');
  }

  /// Reports the switch being timed, once, if it reached any phase, and clears
  /// it. A switch that showed a warm page and loaded nothing reaches no
  /// `pageSettled`, so the next switch's start reports it.
  static void _emitSwitch() {
    final segment = _switch;
    _switch = null;
    if (segment == null || segment.isEmpty) return;
    // The tap anchors the segment at 0ms; the phases follow, timed from it.
    // "tap" names the user action whatever the originating step was.
    LogTag.startup.info('Switch: tap 0ms, ${segment.line}');
  }

  /// Reports the launch once: when the launched page has settled or stopped
  /// being waited for, or when the launch opened no site. Later switches time
  /// from here through [reached] and [stepReached].
  static void end() {
    if (!_clock.isRunning || _ended) return;
    _ended = true;
    final steps = _steps.isEmpty
        ? ''
        : '; activation steps: ${_inOrder(_steps, label: (s) => s.name)}';
    LogTag.startup.info(
        'Launch, from main(): ${_inOrder(_at, label: (m) => m.label)}$steps');
  }
}
