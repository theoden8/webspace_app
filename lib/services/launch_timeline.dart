import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:webspace/services/log_service.dart';

/// A phase of this process's launch, in the order a launch into a site
/// reaches them.
enum LaunchMark {
  runApp('runApp'),
  firstFrame('first frame'),
  sitesOnPage('sites on page'),
  activated('site activated'),
  webViewBuilt('webview built'),
  pageStarted('page started'),
  pageSettled('page settled');

  const LaunchMark(this.label);

  final String label;
}

/// When this launch reached each [LaunchMark], counted from main(), and
/// reported as one App logs line when it ends (DEVTOOLS-013), so a launch
/// can be timed on a device with no debugger attached.
abstract final class LaunchTimeline {
  static final Stopwatch _clock = Stopwatch();
  static final Map<LaunchMark, int> _at = {};
  static bool _ended = false;

  /// main() starts the clock before anything else.
  static void start() => _clock.start();

  @visibleForTesting
  static void resetForTest() {
    _clock
      ..stop()
      ..reset();
    _at.clear();
    _ended = false;
  }

  /// Notes the first time [mark] is reached; a later one is not this
  /// launch's, nor is one after [end].
  static void reached(LaunchMark mark) {
    if (!_clock.isRunning || _ended) return;
    _at.putIfAbsent(mark, () => _clock.elapsedMilliseconds);
  }

  /// Reports the launch once: when the launched page has settled or stopped
  /// being waited for, or when the launch opened no site.
  static void end() {
    if (!_clock.isRunning || _ended) return;
    _ended = true;
    LogTag.startup.info('Launch, from main(): ${[
      for (final mark in LaunchMark.values)
        if (_at[mark] case final ms?) '${mark.label} ${ms}ms',
    ].join(', ')}');
  }
}
