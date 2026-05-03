import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';

/// Records every controller method invocation in order.
///
/// We extend [Fake] so only the methods we override are exposed; any other
/// [WebViewController] method called on this fake throws via [noSuchMethod],
/// which is exactly what we want — the contract under test is "pause/resume
/// touches only the pause-related controller methods, nothing else".
class _RecordingController extends Fake implements WebViewController {
  final List<String> calls = [];

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
  }

  @override
  Future<void> pauseAllJsTimers() async {
    calls.add('pauseAllJsTimers');
  }

  @override
  Future<void> resumeAllJsTimers() async {
    calls.add('resumeAllJsTimers');
  }
}

WebViewModel _modelWith(
  WebViewController? controller, {
  bool notificationsEnabled = false,
}) {
  final m = WebViewModel(
    initUrl: 'https://example.com',
    name: 'Example',
    notificationsEnabled: notificationsEnabled,
  );
  m.controller = controller;
  return m;
}

void main() {
  group('WebViewModel pause/resume API split', () {
    test('pauseWebView() invokes only the per-instance pause', () async {
      final c = _RecordingController();
      await _modelWith(c).pauseWebView();
      expect(c.calls, ['pause']);
    });

    test('resumeWebView() invokes only the per-instance resume', () async {
      final c = _RecordingController();
      await _modelWith(c).resumeWebView();
      expect(c.calls, ['resume']);
    });

    test('pauseWebView() does NOT invoke pauseAllJsTimers (no global timer pause on site switch)', () async {
      final c = _RecordingController();
      await _modelWith(c).pauseWebView();
      expect(c.calls, isNot(contains('pauseAllJsTimers')),
          reason: 'pauseTimers() is process-global on Android — calling it from '
              'a per-site pauseWebView() would freeze every other loaded webview.');
    });

    test('pauseForAppLifecycle() invokes per-instance pause AND global timer pause, in order', () async {
      final c = _RecordingController();
      await _modelWith(c).pauseForAppLifecycle();
      expect(c.calls, ['pause', 'pauseAllJsTimers']);
    });

    test('resumeFromAppLifecycle() invokes per-instance resume AND global timer resume, in order', () async {
      final c = _RecordingController();
      await _modelWith(c).resumeFromAppLifecycle();
      expect(c.calls, ['resume', 'resumeAllJsTimers']);
    });

    test('site-switch round trip touches no global timer state', () async {
      final c = _RecordingController();
      final model = _modelWith(c);
      await model.pauseWebView();
      await model.resumeWebView();
      expect(c.calls, ['pause', 'resume']);
      expect(c.calls.any((s) => s.contains('AllJsTimers')), isFalse,
          reason: 'Site switching must not toggle the process-global JS timer flag.');
    });

    test('lifecycle round trip pauses then resumes the global JS timer flag exactly once', () async {
      final c = _RecordingController();
      final model = _modelWith(c);
      await model.pauseForAppLifecycle();
      await model.resumeFromAppLifecycle();
      expect(c.calls, ['pause', 'pauseAllJsTimers', 'resume', 'resumeAllJsTimers']);
      expect(c.calls.where((s) => s == 'pauseAllJsTimers').length, 1);
      expect(c.calls.where((s) => s == 'resumeAllJsTimers').length, 1);
    });
  });

  group('WebViewModel pause skips notification sites', () {
    test('pauseWebView() with notificationsEnabled is a no-op', () async {
      final c = _RecordingController();
      await _modelWith(c, notificationsEnabled: true).pauseWebView();
      expect(c.calls, isEmpty,
          reason: 'On iOS, per-instance pause uses pauseTimers() (alert-deadlock '
              'hack) which freezes JS — that stalls notification pollers until '
              'the site is resumed. Sites the user opted in to notifications '
              'must keep running on a site switch.');
    });

    test('resumeWebView() still resumes a notification site', () async {
      // pauseWebView is a no-op for notification sites, but resume must
      // still run — site activation always resumes the new active webview,
      // and skipping it would leave a previously-paused (e.g. via the
      // app-lifecycle path) site frozen.
      final c = _RecordingController();
      await _modelWith(c, notificationsEnabled: true).resumeWebView();
      expect(c.calls, ['resume']);
    });
  });

  group('WebViewModel pause/resume null-safety', () {
    test('pauseWebView() with no controller is a no-op', () async {
      final m = _modelWith(null);
      await m.pauseWebView();
    });

    test('resumeWebView() with no controller is a no-op', () async {
      final m = _modelWith(null);
      await m.resumeWebView();
    });

    test('pauseForAppLifecycle() with no controller is a no-op', () async {
      final m = _modelWith(null);
      await m.pauseForAppLifecycle();
    });

    test('resumeFromAppLifecycle() with no controller is a no-op', () async {
      final m = _modelWith(null);
      await m.resumeFromAppLifecycle();
    });
  });
}
