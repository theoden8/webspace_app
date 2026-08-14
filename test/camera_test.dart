import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/camera.dart';

void main() {
  group('cameraAccessModeFromJson', () {
    test('parses each known mode name', () {
      for (final mode in CameraAccessMode.values) {
        expect(cameraAccessModeFromJson(mode.name, null), mode);
      }
    });

    test('an explicit mode name wins over the legacy boolean', () {
      // A model written by a build that emitted both must honour the mode.
      expect(cameraAccessModeFromJson('virtual', true), CameraAccessMode.virtual);
      expect(cameraAccessModeFromJson('block', true), CameraAccessMode.block);
    });

    test('migrates the legacy bool when no mode name is present', () {
      expect(cameraAccessModeFromJson(null, true), CameraAccessMode.real);
      expect(cameraAccessModeFromJson(null, false), CameraAccessMode.block);
    });

    test('defaults to ask for absent / unknown / wrong-typed input', () {
      expect(cameraAccessModeFromJson(null, null), CameraAccessMode.ask);
      expect(cameraAccessModeFromJson('bogus', null), CameraAccessMode.ask);
      expect(cameraAccessModeFromJson(42, null), CameraAccessMode.ask);
      expect(cameraAccessModeFromJson(null, 'true'), CameraAccessMode.ask);
    });
  });

  group('VirtualCameraSource.fromJson', () {
    test('parses a valid image / video source', () {
      final img = VirtualCameraSource.fromJson({
        'kind': 'image',
        'dataUrl': 'data:image/png;base64,AAAA',
        'fileName': 'qr.png',
      });
      expect(img?.kind, 'image');
      expect(img?.isVideo, isFalse);
      expect(img?.fileName, 'qr.png');

      final vid = VirtualCameraSource.fromJson({
        'kind': 'video',
        'dataUrl': 'data:video/mp4;base64,AAAA',
        'fileName': 'clip.mp4',
      });
      expect(vid?.isVideo, isTrue);
    });

    test('defaults fileName to empty when missing', () {
      final s = VirtualCameraSource.fromJson(
          {'kind': 'image', 'dataUrl': 'data:image/png;base64,AAAA'});
      expect(s?.fileName, '');
    });

    test('rejects a non-data URL (crafted backup can not smuggle a fetch)', () {
      for (final url in [
        'https://evil.example/x.png',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'blob:https://example.com/abc',
      ]) {
        expect(
          VirtualCameraSource.fromJson({'kind': 'image', 'dataUrl': url}),
          isNull,
          reason: 'must reject $url',
        );
      }
    });

    test('rejects an unknown kind, missing fields, and non-maps', () {
      expect(
          VirtualCameraSource.fromJson(
              {'kind': 'audio', 'dataUrl': 'data:audio/mp3;base64,AA'}),
          isNull);
      expect(VirtualCameraSource.fromJson({'kind': 'image'}), isNull);
      expect(VirtualCameraSource.fromJson({'dataUrl': 'data:image/png;base64,AA'}),
          isNull);
      expect(VirtualCameraSource.fromJson(null), isNull);
      expect(VirtualCameraSource.fromJson('nope'), isNull);
    });
  });

  group('CameraDecision.toBridgeJson', () {
    test('real / block carry only the mode', () {
      expect(const CameraDecision(CameraAccessMode.real).toBridgeJson(),
          {'mode': 'real'});
      expect(const CameraDecision(CameraAccessMode.block).toBridgeJson(),
          {'mode': 'block'});
      expect(const CameraDecision.block().toBridgeJson(), {'mode': 'block'});
    });

    test('ask degrades to block so the shim never falls through to real', () {
      // An unresolved decision must never tell the shim to open the camera.
      expect(const CameraDecision(CameraAccessMode.ask).toBridgeJson(),
          {'mode': 'block'});
    });

    test('virtual carries the source only when present', () {
      const withSource = CameraDecision(
        CameraAccessMode.virtual,
        VirtualCameraSource(
          kind: 'image',
          dataUrl: 'data:image/png;base64,AAAA',
          fileName: 'qr.png',
        ),
      );
      expect(withSource.toBridgeJson(), {
        'mode': 'virtual',
        'source': {'kind': 'image', 'dataUrl': 'data:image/png;base64,AAAA'},
      });

      // No source picked yet: mode still virtual, but no source key (the
      // shim rejects and the picker is re-offered).
      expect(const CameraDecision(CameraAccessMode.virtual).toBridgeJson(),
          {'mode': 'virtual'});
    });
  });
}
