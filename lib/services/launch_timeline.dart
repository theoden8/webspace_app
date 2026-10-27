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
  themed('themed'),
  routes('routes'),
  activated('site activated'),
  webViewBuilt('webview built'),
  pageStarted('page started'),
  pageSettled('page settled');

  const LaunchMark(this.label);

  final String label;
}

/// When this launch reached each [LaunchMark] and first marked each
/// [ActivationStep], counted from main(), and reported as one App logs line
/// when it ends (DEVTOOLS-013), so a launch can be timed on a device with no
/// debugger attached.
abstract final class LaunchTimeline {
  static final Stopwatch _clock = Stopwatch();
  static final Map<LaunchMark, int> _at = {};
  static final Map<ActivationStep, int> _steps = {};
  static bool _ended = false;

  /// main() starts the clock before anything else.
  static void start() => _clock.start();

  @visibleForTesting
  static void resetForTest() {
    _clock
      ..stop()
      ..reset();
    _at.clear();
    _steps.clear();
    _ended = false;
  }

  /// Notes the first time [mark] is reached; a later one is not this
  /// launch's, nor is one after [end].
  static void reached(LaunchMark mark) {
    if (!_clock.isRunning || _ended) return;
    _at.putIfAbsent(mark, () => _clock.elapsedMilliseconds);
  }

  /// Notes the first time the launch marked [step]; main() hands this to
  /// [ActivationSteps.sink].
  static void stepReached(ActivationStep step) {
    if (!_clock.isRunning || _ended) return;
    _steps.putIfAbsent(step, () => _clock.elapsedMilliseconds);
  }

  static String _inOrder<T extends Enum>(Map<T, int> at,
      {required String Function(T) label}) {
    final reached = at.entries.toList()
      ..sort((a, b) => a.value != b.value
          ? a.value.compareTo(b.value)
          : a.key.index.compareTo(b.key.index));
    return [for (final e in reached) '${label(e.key)} ${e.value}ms'].join(', ');
  }

  /// Reports the launch once: when the launched page has settled or stopped
  /// being waited for, or when the launch opened no site.
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
