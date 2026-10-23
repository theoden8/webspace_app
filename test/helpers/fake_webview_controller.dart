import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/webview_controller.dart';

/// [WebViewController] that records the pause/resume, load, JavaScript,
/// cache, state and history calls it receives. Any other member is
/// unimplemented and fails the test reaching it.
class FakeWebViewController extends Fake implements WebViewController {
  final List<String> calls = [];
  final List<String> evaluated = [];

  /// What [backEntry] answers; a test may move the page on before it does.
  Future<HistoryEntry?> Function() backEntryAnswer = () async => null;

  /// Awaited before the calls a schedule holds, as `MockCookieManager.pace`:
  /// every one an activation, an unload or memory pressure waits on.
  Future<void> Function(PlatformCall call)? pace;

  @override
  Future<void> clearCache() async {
    await pace?.call(PlatformCall.webViewClearCache);
    calls.add('clearCache');
  }

  /// What [saveState] returns: the back stack this webview holds.
  Uint8List history = Uint8List.fromList(const [1]);

  @override
  Future<Uint8List?> saveState() async {
    await pace?.call(PlatformCall.webViewSaveState);
    calls.add('saveState');
    return history;
  }

  @override
  Future<void> pause() async {
    await pace?.call(PlatformCall.webViewPause);
    calls.add('pause');
  }

  @override
  Future<void> resume() async {
    await pace?.call(PlatformCall.webViewResume);
    calls.add('resume');
  }

  @override
  Future<void> pauseAllJsTimers() async => calls.add('pauseAllJsTimers');

  @override
  Future<void> resumeAllJsTimers() async => calls.add('resumeAllJsTimers');

  @override
  Future<void> evaluateJavascript(String source) async {
    await pace?.call(PlatformCall.webViewEvaluateJavascript);
    calls.add('evaluateJavascript');
    evaluated.add(source);
  }

  @override
  Future<void> loadUrl(String url, {String? language}) async =>
      calls.add('loadUrl $url');

  /// Whether the app told this webview to load nothing more.
  bool networkBlocked = false;

  @override
  Future<void> blockNetworkLoads() async => networkBlocked = true;

  @override
  Future<HistoryEntry?> backEntry() {
    calls.add('backEntry');
    return backEntryAnswer();
  }
}
