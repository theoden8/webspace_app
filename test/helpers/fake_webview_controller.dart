import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';

/// [WebViewController] that records the pause/resume, load and JavaScript
/// calls it receives. Any other member is unimplemented and fails the test
/// reaching it.
class FakeWebViewController extends Fake implements WebViewController {
  final List<String> calls = [];
  final List<String> evaluated = [];

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
}
