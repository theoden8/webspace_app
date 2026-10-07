import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/capture_permission_engine.dart';
import 'package:webspace/settings/capture.dart';

/// Plays the host: which kinds the site's store opens, which OS permissions
/// the app holds, and what was asked in what order.
final class _Host {
  _Host({
    this.open = const {},
    this.camera = true,
    this.microphone = true,
  });

  final Set<CaptureKind> open;
  final bool camera;
  final bool microphone;
  final List<Object> asked = [];

  DeviceGrantHost get host => (
    opensDevice: (kind) async {
      asked.add(kind);
      return open.contains(kind);
    },
    cameraPermission: () async {
      asked.add('camera permission');
      return camera;
    },
    microphonePermission: () async {
      asked.add('microphone permission');
      return microphone;
    },
  );
}

const _mic = (camera: false, microphone: true, other: false);
const _cam = (camera: true, microphone: false, other: false);
const _both = (camera: true, microphone: true, other: false);
const _all = {CaptureKind.camera, CaptureKind.microphone};

Future<DeviceAnswer> _answer(DeviceRequest request, _Host host) =>
    CapturePermissionEngine.answer(request, host.host);

void main() {
  group('a microphone request (MIC-003)', () {
    test('is granted for a real site holding the recording permission',
        () async {
      final host = _Host(open: {CaptureKind.microphone});
      expect(await _answer(_mic, host), DeviceAnswer.grant);
      expect(host.asked, [CaptureKind.microphone, 'microphone permission']);
    });

    test('is denied, never prompted, when the store does not open it',
        () async {
      final host = _Host();
      expect(await _answer(_mic, host), DeviceAnswer.deny);
      expect(host.asked, [CaptureKind.microphone],
          reason: 'a denied site raises no OS prompt');
    });

    test('is denied without the app-level permission (MIC-015)', () async {
      final host = _Host(open: {CaptureKind.microphone}, microphone: false);
      expect(await _answer(_mic, host), DeviceAnswer.deny);
    });

    test('bundled with an unknown resource is still answered', () async {
      final host = _Host();
      expect(
        await _answer((camera: false, microphone: true, other: true), host),
        DeviceAnswer.deny,
      );
    });
  });

  group('a camera and microphone request', () {
    test('needs both devices open, since it cannot be half-granted', () async {
      expect(await _answer(_both, _Host(open: _all)), DeviceAnswer.grant);
      expect(await _answer(_both, _Host(open: {CaptureKind.microphone})),
          DeviceAnswer.deny);
      expect(await _answer(_both, _Host(open: {CaptureKind.camera})),
          DeviceAnswer.deny);
    });

    test('needs both OS permissions', () async {
      expect(await _answer(_both, _Host(open: _all, camera: false)),
          DeviceAnswer.deny);
      expect(await _answer(_both, _Host(open: _all, microphone: false)),
          DeviceAnswer.deny);
    });

    test('asks both decisions before either OS permission', () async {
      final host = _Host(open: _all);
      await _answer(_both, host);
      expect(host.asked, [
        CaptureKind.microphone,
        CaptureKind.camera,
        'microphone permission',
        'camera permission',
      ]);
    });
  });

  group('a camera-only request (CAM-001, CAM-004)', () {
    test('is granted for a real site holding the camera permission', () async {
      final host = _Host(open: {CaptureKind.camera});
      expect(await _answer(_cam, host), DeviceAnswer.grant);
      expect(host.asked, [CaptureKind.camera, 'camera permission']);
    });

    test('is denied when the store does not open it', () async {
      expect(await _answer(_cam, _Host()), DeviceAnswer.deny);
    });

    test('bundled with something else is left to the platform', () async {
      final host = _Host(open: _all);
      expect(
        await _answer((camera: true, microphone: false, other: true), host),
        DeviceAnswer.prompt,
      );
      expect(host.asked, isEmpty);
    });
  });

  test('a request for no device is left to the platform', () async {
    final host = _Host(open: _all);
    expect(
      await _answer((camera: false, microphone: false, other: true), host),
      DeviceAnswer.prompt,
    );
    expect(host.asked, isEmpty);
  });
}
