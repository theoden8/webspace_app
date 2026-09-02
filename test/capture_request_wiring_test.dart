import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/screen_share.dart';
import 'package:webspace/web_view_model.dart';

/// Drives the wiring a real `WebViewModel` hands to `WebViewConfig`, rather
/// than an engine with a fake host.
///
/// The engine tests prove the gate; they cannot prove this model reaches it
/// correctly. Wire `isActive` to the wrong thing — or to a bare `true` to
/// make something compile — and every engine test still passes while a
/// backgrounded site prompts (CAM-011 / MIC-011 / SHARE-011). These call the
/// model's own resolvers, which is what `getWebView` installs into the config.

const _camSrc = VirtualCameraSource(
  kind: 'image',
  dataUrl: 'data:image/png;base64,AAAA',
  fileName: 'qr.png',
);
const _micSrc = VirtualMicrophoneSource(
  dataUrl: 'data:audio/mpeg;base64,AAAA',
  fileName: 'tone.mp3',
);
const _screenSrc = VirtualScreenSource(
  kind: 'image',
  dataUrl: 'data:image/png;base64,AAAA',
  fileName: 'slide.png',
);

WebViewModel _site({
  CameraAccessMode camera = CameraAccessMode.ask,
  MicrophoneAccessMode microphone = MicrophoneAccessMode.ask,
  ScreenShareMode screenShare = ScreenShareMode.ask,
  bool archived = false,
}) =>
    WebViewModel(
      initUrl: 'https://bank.example',
      cameraMode: camera,
      virtualCameraSource: camera == CameraAccessMode.virtual ? _camSrc : null,
      microphoneMode: microphone,
      virtualMicrophoneSource:
          microphone == MicrophoneAccessMode.virtual ? _micSrc : null,
      screenShareMode: screenShare,
      virtualScreenSource:
          screenShare == ScreenShareMode.virtual ? _screenSrc : null,
      isArchiveTier: archived,
    );

void main() {
  group('WebViewModel.resolveCameraRequest', () {
    test('a backgrounded site is denied without prompting (CAM-011)', () async {
      for (final mode in CameraAccessMode.values) {
        final model = _site(camera: mode);
        var saves = 0;
        final d = await model.resolveCameraRequest(
          'https://bank.example',
          resolver: (_, _) async => fail('a background site must not prompt'),
          isActive: () => false,
          saveFunc: () => saves++,
        );
        expect(d.mode, CameraAccessMode.block, reason: 'stored mode $mode');
        expect(model.cameraMode, mode, reason: 'stored decision left intact');
        expect(saves, 0);
      }
    });

    test('the active site resolves and persists normally', () async {
      final model = _site();
      var saves = 0;
      final d = await model.resolveCameraRequest(
        'https://bank.example',
        resolver: (_, _) async => const CameraDecision(CameraAccessMode.real),
        isActive: () => true,
        saveFunc: () => saves++,
      );
      expect(d.mode, CameraAccessMode.real);
      expect(model.cameraMode, CameraAccessMode.real);
      expect(saves, 1);
    });

    test('a site with no activity predicate counts as active', () async {
      final model = _site(camera: CameraAccessMode.real);
      final d = await model.resolveCameraRequest(
        'https://bank.example',
        resolver: (_, _) async => fail('a settled mode must not prompt'),
        isActive: null,
        saveFunc: () {},
      );
      expect(d.mode, CameraAccessMode.real);
    });

    test('the archive-tier fold survives the wiring (CAM-006)', () async {
      final model = _site(camera: CameraAccessMode.virtual, archived: true);
      final d = await model.resolveCameraRequest(
        'https://bank.example',
        resolver: (_, _) async => fail('an archive site must not prompt'),
        isActive: () => true,
        saveFunc: () {},
      );
      expect(d.mode, CameraAccessMode.block);
      expect(model.cameraMode, CameraAccessMode.virtual,
          reason: 'preserved for when the site leaves the archive');
    });
  });

  group('WebViewModel.resolveMicrophoneRequest', () {
    test('a backgrounded site is denied without prompting (MIC-011)', () async {
      for (final mode in MicrophoneAccessMode.values) {
        final model = _site(microphone: mode);
        var saves = 0;
        final d = await model.resolveMicrophoneRequest(
          'https://meet.example',
          resolver: (_, _) async => fail('a background site must not prompt'),
          isActive: () => false,
          saveFunc: () => saves++,
        );
        expect(d.mode, MicrophoneAccessMode.block, reason: 'stored mode $mode');
        expect(model.microphoneMode, mode,
            reason: 'stored decision left intact');
        expect(saves, 0);
      }
    });

    test('the active site resolves and persists normally', () async {
      final model = _site();
      var saves = 0;
      final d = await model.resolveMicrophoneRequest(
        'https://meet.example',
        resolver: (_, _) async =>
            const MicrophoneDecision(MicrophoneAccessMode.virtual, _micSrc),
        isActive: () => true,
        saveFunc: () => saves++,
      );
      expect(d.mode, MicrophoneAccessMode.virtual);
      expect(model.microphoneMode, MicrophoneAccessMode.virtual);
      expect(model.virtualMicrophoneSource?.fileName, 'tone.mp3');
      expect(saves, 1);
    });

    test('a site with no activity predicate counts as active', () async {
      final model = _site(microphone: MicrophoneAccessMode.virtual);
      final d = await model.resolveMicrophoneRequest(
        'https://meet.example',
        resolver: (_, _) async => fail('a settled mode must not prompt'),
        isActive: null,
        saveFunc: () {},
      );
      expect(d.mode, MicrophoneAccessMode.virtual);
      expect(d.source?.fileName, 'tone.mp3');
    });

    test('the archive-tier fold survives the wiring (MIC-006)', () async {
      final model = _site(microphone: MicrophoneAccessMode.virtual, archived: true);
      final d = await model.resolveMicrophoneRequest(
        'https://meet.example',
        resolver: (_, _) async => fail('an archive site must not prompt'),
        isActive: () => true,
        saveFunc: () {},
      );
      expect(d.mode, MicrophoneAccessMode.block);
      expect(model.microphoneMode, MicrophoneAccessMode.virtual,
          reason: 'preserved for when the site leaves the archive');
    });

    test('a backgrounded site is denied even mid-switch, per request',
        () async {
      // The activity predicate is read at decide() time, not captured once:
      // a site that loses focus between two requests must flip to denied.
      var active = true;
      final model = _site(microphone: MicrophoneAccessMode.virtual);
      final first = await model.resolveMicrophoneRequest(
        'https://meet.example',
        resolver: (_, _) async => fail('a settled mode must not prompt'),
        isActive: () => active,
        saveFunc: () {},
      );
      expect(first.mode, MicrophoneAccessMode.virtual);
      active = false;
      final second = await model.resolveMicrophoneRequest(
        'https://meet.example',
        resolver: (_, _) async => fail('a background site must not prompt'),
        isActive: () => active,
        saveFunc: () {},
      );
      expect(second.mode, MicrophoneAccessMode.block);
    });
  });

  group('WebViewModel.resolveScreenShareRequest', () {
    test('a backgrounded site is denied without prompting (SHARE-011)',
        () async {
      for (final mode in ScreenShareMode.values) {
        final model = _site(screenShare: mode);
        var saves = 0;
        final d = await model.resolveScreenShareRequest(
          'https://meet.example',
          resolver: (_, _) async => fail('a background site must not prompt'),
          isActive: () => false,
          saveFunc: () => saves++,
        );
        expect(d.mode, ScreenShareMode.block, reason: 'stored mode $mode');
        expect(model.screenShareMode, mode,
            reason: 'stored decision left intact');
        expect(saves, 0);
      }
    });

    test('the active site resolves and persists normally', () async {
      final model = _site();
      var saves = 0;
      final d = await model.resolveScreenShareRequest(
        'https://meet.example',
        resolver: (_, _) async =>
            const ScreenShareDecision(ScreenShareMode.virtual, _screenSrc),
        isActive: () => true,
        saveFunc: () => saves++,
      );
      expect(d.mode, ScreenShareMode.virtual);
      expect(model.screenShareMode, ScreenShareMode.virtual);
      expect(model.virtualScreenSource?.fileName, 'slide.png');
      expect(saves, 1);
    });

    test('a site with no activity predicate counts as active', () async {
      final model = _site(screenShare: ScreenShareMode.virtual);
      final d = await model.resolveScreenShareRequest(
        'https://meet.example',
        resolver: (_, _) async => fail('a settled mode must not prompt'),
        isActive: null,
        saveFunc: () {},
      );
      expect(d.mode, ScreenShareMode.virtual);
      expect(d.source?.fileName, 'slide.png');
    });

    test('the archive-tier fold survives the wiring (SHARE-006)', () async {
      final model =
          _site(screenShare: ScreenShareMode.virtual, archived: true);
      final d = await model.resolveScreenShareRequest(
        'https://meet.example',
        resolver: (_, _) async => fail('an archive site must not prompt'),
        isActive: () => true,
        saveFunc: () {},
      );
      expect(d.mode, ScreenShareMode.block);
      expect(model.screenShareMode, ScreenShareMode.virtual,
          reason: 'preserved for when the site leaves the archive');
    });

    test('no resolver answer can produce a real-display grant (SHARE-001)',
        () async {
      // The host UI is the only thing that could widen this, and it has no
      // value to widen it to: every mode the resolver can return maps to a
      // bridge payload the shim reads as "serve a file" or "deny".
      for (final mode in ScreenShareMode.values) {
        final model = _site();
        final d = await model.resolveScreenShareRequest(
          'https://meet.example',
          resolver: (_, _) async => ScreenShareDecision(mode, _screenSrc),
          isActive: () => true,
          saveFunc: () {},
        );
        expect(d.toBridgeJson()['mode'], isIn(['virtual', 'block']),
            reason: mode.name);
      }
    });
  });
}
