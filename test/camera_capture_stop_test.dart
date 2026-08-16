import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/web_view_model.dart';

/// Records the JS a deactivation posts into the page. Extends [Fake] so any
/// other controller call throws: stopping capture must touch nothing else.
class _RecordingController extends Fake implements WebViewController {
  final List<String> evaluated = [];

  @override
  Future<void> evaluateJavascript(String source) async {
    evaluated.add(source);
  }
}

class _ThrowingController extends Fake implements WebViewController {
  @override
  Future<void> evaluateJavascript(String source) async {
    throw StateError('controller disposed');
  }
}

WebViewModel _model(
  WebViewController? controller, {
  bool notificationsEnabled = false,
  bool backgroundAudioEnabled = false,
  CameraAccessMode cameraMode = CameraAccessMode.real,
}) {
  final m = WebViewModel(
    initUrl: 'https://bank.example',
    name: 'Bank',
    notificationsEnabled: notificationsEnabled,
    backgroundAudioEnabled: backgroundAudioEnabled,
    cameraMode: cameraMode,
  );
  m.controller = controller;
  return m;
}

void main() {
  group('stopRealCameraCapture (CAM-012)', () {
    test('posts the shim hook into the page', () async {
      final c = _RecordingController();
      await _model(c).stopRealCameraCapture();
      expect(c.evaluated, hasLength(1));
      expect(c.evaluated.single, contains('__wsStopRealCapture'));
    });

    test('guards on the hook so a page without the shim is a no-op', () async {
      final c = _RecordingController();
      await _model(c).stopRealCameraCapture();
      // The shim returns early on a platform with no mediaDevices, so the
      // hook can legitimately be absent; an unguarded call would throw a
      // ReferenceError into the page.
      expect(c.evaluated.single, contains("typeof globalThis.__wsStopRealCapture === 'function'"));
    });

    test('no controller is a no-op rather than a throw', () async {
      await _model(null).stopRealCameraCapture();
    });

    test('a disposed controller is swallowed', () async {
      await _model(_ThrowingController()).stopRealCameraCapture();
    });

    test('notification sites still stop capture', () async {
      // pauseWebView() early-returns for these, which is exactly why the stop
      // is a separate call: their JS keeps running in the background, so a
      // capture would too.
      final c = _RecordingController();
      await _model(c, notificationsEnabled: true).stopRealCameraCapture();
      expect(c.evaluated, hasLength(1));
    });

    test('background-audio sites still stop capture', () async {
      final c = _RecordingController();
      await _model(c, backgroundAudioEnabled: true).stopRealCameraCapture();
      expect(c.evaluated, hasLength(1));
    });

    test('runs for a simulated-camera site too; the shim decides what ends',
        () async {
      // Dart does not branch on the mode: the page may hold a device track
      // from before the mode changed, and only the shim knows which tracks
      // are synthetic.
      final c = _RecordingController();
      await _model(c, cameraMode: CameraAccessMode.virtual)
          .stopRealCameraCapture();
      expect(c.evaluated, hasLength(1));
    });
  });
}
