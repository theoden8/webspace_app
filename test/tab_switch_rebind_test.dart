import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A site's `activeTabId` names the tab its one webview is showing. The two
/// have to move together: `_switchActiveTab` is the only path that captures
/// the outgoing tab's back stack, disposes the webview and queues the incoming
/// tab's bytes, so an assignment that skips it leaves a live webview rendering
/// one tab while the model, the app bar and the tab list all name another —
/// and the outgoing tab's stack is lost rather than parked.
///
/// A site with no webview is the one case where the bare assignment is right:
/// there is nothing on screen to disagree with, and the activation that
/// follows builds the webview against whichever tab is active by then. That is
/// why every such assignment must sit behind a `_loadedIndices` check.
///
/// This shipped broken once: `_newTab` moved `activeTabId` for any site that
/// was not the current one, which is true of a loaded-but-backgrounded site
/// too. Structural, because `_WebSpacePageState` is not constructible from a
/// unit test.
void main() {
  late String source;
  late List<String> lines;

  setUpAll(() {
    source = File('lib/main.dart').readAsStringSync();
    lines = source.split('\n');
  });

  /// The half-open line range `[start, end)` of a method body, found by its
  /// signature and the closing brace at its own indent.
  (int, int) methodRange(String signature) {
    final start = lines.indexWhere((l) => l.contains(signature));
    expect(start, isNot(-1), reason: '$signature not found in lib/main.dart');
    final end = lines.indexWhere((l) => l == '  }', start);
    expect(end, isNot(-1), reason: 'could not find the end of $signature');
    return (start, end);
  }

  test('_switchActiveTab is the only unguarded way to move activeTabId', () {
    final (switchStart, switchEnd) =
        methodRange('Future<void> _switchActiveTab(');

    final offenders = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains('activeTabId = ')) continue;
      if (i >= switchStart && i < switchEnd) continue; // the sanctioned path
      // Look back a few lines for the guard that makes a bare assignment safe.
      final window = lines
          .sublist(i - 12 < 0 ? 0 : i - 12, i)
          .join('\n');
      if (window.contains('_loadedIndices.contains(index)')) continue;
      offenders.add('line ${i + 1}: ${lines[i].trim()}');
    }

    expect(
      offenders,
      isEmpty,
      reason: 'each of these moves a site\'s active tab without going through '
          '_switchActiveTab and without first establishing that the site has '
          'no webview to re-bind. Either call _switchActiveTab, or guard the '
          'assignment with _loadedIndices.contains(index).',
    );
  });

  test('_switchActiveTab captures, queues and disposes in that order', () {
    final (start, end) = methodRange('Future<void> _switchActiveTab(');
    final body = lines.sublist(start, end).join('\n');

    final capture = body.indexOf('_captureStateBytes(model)');
    final move = body.indexOf('model.activeTabId = targetTabId');
    final queue = body.indexOf('schedulePendingRestoreState(');
    final dispose = body.indexOf('model.disposeWebView()');

    expect(capture, isNot(-1), reason: 'the outgoing tab\'s stack is parked');
    expect(queue, isNot(-1), reason: 'the incoming tab\'s stack is restored');
    expect(dispose, isNot(-1), reason: 'restoreState needs a fresh controller');

    // Capture reads `model.activeStateKey`, so it has to run while that still
    // names the tab being left.
    expect(capture, lessThan(move),
        reason: 'capturing after the move would write the outgoing tab\'s '
            'bytes under the incoming tab\'s key');
    // The queue is consumed by onControllerCreated, which only runs because
    // the dispose makes the next build create a controller.
    expect(queue, lessThan(dispose),
        reason: 'bytes queued after the dispose miss the rebuild that was '
            'supposed to consume them');
  });

  test('a tab switch never builds a second webview for the site', () {
    final (start, end) = methodRange('Future<void> _switchActiveTab(');
    final body = lines.sublist(start, end).join('\n');
    // One dispose, no getWebView / getController: the rebuild is the
    // IndexedStack's, after setState. Two webviews for one site would double
    // the renderer cost that tabs exist to avoid (TAB-002).
    expect(
      RegExp(RegExp.escape('model.disposeWebView()')).allMatches(body).length,
      1,
    );
    expect(body.contains('getWebView('), isFalse);
  });
}
