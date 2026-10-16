import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview_controller.dart';

/// [WebViewController] that records the pause/resume, load, JavaScript and
/// history calls it receives. Any other member is unimplemented and fails the test
/// reaching it.
class FakeWebViewController extends Fake implements WebViewController {
  final List<String> calls = [];
  final List<String> evaluated = [];

  /// What [backEntry] answers; a test may move the page on before it does.
  Future<HistoryEntry?> Function() backEntryAnswer = () async => null;

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> pauseAllJsTimers() async => calls.add('pauseAllJsTimers');

  @override
  Future<void> resumeAllJsTimers() async => calls.add('resumeAllJsTimers');

  @override
  Future<void> evaluateJavascript(String source) async {
    calls.add('evaluateJavascript');
    evaluated.add(source);
  }

  @override
  Future<void> loadUrl(String url, {String? language}) async =>
      calls.add('loadUrl $url');

  @override
  Future<HistoryEntry?> backEntry() {
    calls.add('backEntry');
    return backEntryAnswer();
  }
}
