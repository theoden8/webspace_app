import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/capture_fakes.dart';

/// The JSON a site stores for [kind] alone.
Map<String, dynamic> _json(CaptureKind kind, {Object? mode}) => {
  kind.jsonKeys.first: ?mode,
};

CaptureMode _modeFrom(CaptureKind kind, Map<String, dynamic> json) =>
    kind.grantOf(CaptureGrants.fromJson(json)).mode;

const _image = VirtualVisualSource(
  kind: 'image',
  dataUrl: 'data:image/png;base64,AAAA',
  fileName: 'qr.png',
);
const _clip = VirtualAudioSource(
  dataUrl: 'data:audio/mpeg;base64,AAAA',
  fileName: 'tone.mp3',
);

void main() {
  group('CaptureKind', () {
    test('keys, handlers and shim groups are distinct per kind', () {
      final kinds = CaptureKind.values;
      for (final facts in <Iterable<Object?>>[
        kinds.expand((k) => k.jsonKeys),
        kinds.map((k) => k.requestHandler),
        kinds.map((k) => k.publishedDevice?.modeHandler).nonNulls,
        kinds.map((k) => k.shimGroup),
      ]) {
        expect(facts.toSet(), hasLength(facts.length));
      }
    });

    test('screen sharing has no real mode and reaches the top frame only '
        '(SHARE-001 / SHARE-005)', () {
      expect(CaptureKind.screenShare.real, isNull);
      expect(CaptureKind.screenShare.modes.map((m) => m.state),
          isNot(contains(SitePermissionState.allowed)));
      expect(CaptureKind.screenShare.reachesSubframes, isFalse);
    });

    test('the camera and microphone keep reaching cross-origin frames', () {
      // A QR scanner embedded in a frame is the case they exist for.
      expect(CaptureKind.camera.reachesSubframes, isTrue);
      expect(CaptureKind.microphone.reachesSubframes, isTrue);
    });

    test('each mode enum projects onto the shared states one to one', () {
      for (final kind in CaptureKind.values) {
        expect(kind.modes.map((m) => m.state).toSet(), hasLength(kind.modes.length));
        expect(kind.ask.state, SitePermissionState.ask);
        expect(kind.virtual.state, SitePermissionState.simulated);
        expect(kind.block.state, SitePermissionState.blocked);
        expect(kind.real?.state, kind.real == null ? null : SitePermissionState.allowed);
      }
    });
  });

  group('stored modes', () {
    for (final kind in CaptureKind.values) {
      test('$kind: every mode name round-trips', () {
        for (final mode in kind.modes) {
          expect(_modeFrom(kind, _json(kind, mode: mode.name)), mode);
        }
      });

      test('$kind: absent, unknown or wrong-typed reads as ask', () {
        for (final stored in [null, 'bogus', 42, true]) {
          expect(_modeFrom(kind, _json(kind, mode: stored)), kind.ask,
              reason: '$stored');
        }
      });
    }

    test('a name the build does not know reads as ask, never as a grant', () {
      // A crafted backup, or a downgrade from a build with more modes.
      for (final smuggled in ['real', 'allow', 'monitor', 'screen']) {
        expect(_modeFrom(CaptureKind.screenShare,
            _json(CaptureKind.screenShare, mode: smuggled)),
            ScreenShareMode.ask, reason: smuggled);
      }
    });

    test('the legacy cameraAllowed bool migrates; a mode name wins over it', () {
      expect(_modeFrom(CaptureKind.camera, {'cameraAllowed': true}),
          CameraAccessMode.real);
      expect(_modeFrom(CaptureKind.camera, {'cameraAllowed': false}),
          CameraAccessMode.block);
      expect(_modeFrom(CaptureKind.camera, {'cameraAllowed': 'true'}),
          CameraAccessMode.ask);
      expect(_modeFrom(CaptureKind.camera,
          {'cameraMode': 'virtual', 'cameraAllowed': true}),
          CameraAccessMode.virtual);
      expect(_modeFrom(CaptureKind.microphone, {'cameraAllowed': true}),
          MicrophoneAccessMode.ask, reason: 'the legacy key is the camera\'s');
    });
  });

  group('VirtualVisualSource.fromJson', () {
    test('parses an image or a video, defaulting the file name', () {
      expect(VirtualVisualSource.fromJson(_image.toJson()), _image);
      final video = VirtualVisualSource.fromJson(
          {'kind': 'video', 'dataUrl': 'data:video/mp4;base64,AAAA'});
      expect(video?.isVideo, isTrue);
      expect(video?.fileName, '');
    });

    test('rejects a non-data URL, an unknown kind, missing fields', () {
      for (final bad in <Object?>[
        {'kind': 'image', 'dataUrl': 'https://evil.example/x.png'},
        {'kind': 'image', 'dataUrl': 'file:///etc/passwd'},
        {'kind': 'image', 'dataUrl': 'javascript:alert(1)'},
        {'kind': 'image', 'dataUrl': 'blob:https://example.com/abc'},
        {'kind': 'audio', 'dataUrl': 'data:audio/mp3;base64,AA'},
        {'kind': 'image'},
        {'dataUrl': 'data:image/png;base64,AA'},
        'data:image/png;base64,AA',
        null,
      ]) {
        expect(VirtualVisualSource.fromJson(bad), isNull, reason: '$bad');
      }
    });
  });

  group('VirtualAudioSource.fromJson', () {
    test('parses a clip, defaulting the file name', () {
      expect(VirtualAudioSource.fromJson(_clip.toJson()), _clip);
      expect(VirtualAudioSource.fromJson(
          {'dataUrl': 'data:audio/mpeg;base64,AAAA'})?.fileName, '');
    });

    test('rejects a non-data URL, missing fields and non-maps', () {
      for (final bad in <Object?>[
        {'dataUrl': 'https://evil.example/x.mp3'},
        {'dataUrl': 'file:///etc/passwd'},
        {'fileName': 'x.mp3'},
        'data:audio/mpeg;base64,AA',
        null,
      ]) {
        expect(VirtualAudioSource.fromJson(bad), isNull, reason: '$bad');
      }
    });
  });

  test('bytes decodes the base64 payload, null without one', () {
    expect(const VirtualAudioSource(
        dataUrl: 'data:audio/wav;base64,3q2+7w==', fileName: 'a').bytes,
        [0xDE, 0xAD, 0xBE, 0xEF]);
    expect(const VirtualVisualSource(
        kind: 'image', dataUrl: 'data:image/png,plain', fileName: 'x').bytes,
        isNull);
    expect(const VirtualVisualSource(
        kind: 'image', dataUrl: 'data:image/png;base64,!!', fileName: 'x').bytes,
        isNull);
  });

  group('toBridgeJson', () {
    for (final kind in CaptureKind.values) {
      test('$kind: ask and block deny', () {
        expect((mode: kind.ask, source: pickedFor(kind)).toBridgeJson(),
            {'mode': 'block'});
        expect((mode: kind.block, source: null).toBridgeJson(),
            {'mode': 'block'});
      });

      test('$kind: virtual carries the source, never its file name', () {
        final grant = (mode: kind.virtual, source: pickedFor(kind));
        expect(grant.toBridgeJson(), {
          'mode': 'virtual',
          'source': pickedFor(kind).toBridgeJson(),
        });
        expect(grant.toBridgeJson().toString(), isNot(contains('picked.bin')));
        expect((mode: kind.virtual, source: null).toBridgeJson(),
            {'mode': 'virtual'});
      });
    }

    test('the two source shapes the shims read', () {
      expect((mode: CameraAccessMode.virtual, source: _image).toBridgeJson(), {
        'mode': 'virtual',
        'source': {'kind': 'image', 'dataUrl': 'data:image/png;base64,AAAA'},
      });
      expect((mode: MicrophoneAccessMode.virtual, source: _clip).toBridgeJson(),
          {'mode': 'virtual', 'source': {'dataUrl': 'data:audio/mpeg;base64,AAAA'}});
      expect((mode: MicrophoneAccessMode.real, source: null).toBridgeJson(),
          {'mode': 'real'});
    });
  });

  group('WebViewModel captures', () {
    test('an untouched site writes no capture key', () {
      final json = WebViewModel(initUrl: 'https://example.com').toJson();
      for (final kind in CaptureKind.values) {
        for (final key in kind.jsonKeys) {
          expect(json.containsKey(key), isFalse, reason: key);
        }
      }
    });

    for (final kind in CaptureKind.values) {
      test('$kind: mode and file round-trip', () {
        final model = siteWith(kind, kind.virtual, withSource: true);
        final back = WebViewModel.fromJson(model.toJson(), null);
        expect(kind.grantOf(back.captures),
            (mode: kind.virtual, source: pickedFor(kind)));
      });

      test('$kind: an archive-tier site is blocked, its intent kept '
          '(CAM-006 / MIC-006 / SHARE-006)', () {
        final model =
            siteWith(kind, kind.virtual, withSource: true, archived: true);
        expect(kind.grantOf(model.effectiveCaptures).mode, kind.block);
        expect(kind.grantOf(model.effectiveCaptures).source, pickedFor(kind));
        expect(kind.grantOf(model.captures).mode, kind.virtual);
      });

      test('$kind: the decision never rides the settings QR '
          '(CAM-007 / MIC-007 / SHARE-007)', () {
        final model = siteWith(kind, kind.virtual, withSource: true);
        final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
        for (final key in kind.jsonKeys) {
          expect(shared.containsKey(key), isFalse, reason: key);
        }
      });
    }

    test('an import resets every real grant to ask, keeping the rest', () {
      final site = WebViewModel(
        initUrl: 'https://example.com',
        captures: CaptureGrants.none.copyWith(
          camera: (mode: CameraAccessMode.real, source: null),
          microphone: (mode: MicrophoneAccessMode.real, source: null),
          screenShare: (mode: ScreenShareMode.virtual, source: _image),
        ),
      );
      sanitizeImportedSites([site]);
      expect(site.captures.camera.mode, CameraAccessMode.ask);
      expect(site.captures.microphone.mode, MicrophoneAccessMode.ask);
      expect(site.captures.screenShare, (mode: ScreenShareMode.virtual, source: _image));
    });
  });

  group('VirtualMediaPicker', () {
    test('every accepted extension maps to its medium\'s MIME type', () {
      for (final ext in VirtualMediaPicker.imageExtensions) {
        expect(VirtualMediaPicker.mimeForExtension(ext, false),
            startsWith('image/'), reason: ext);
      }
      for (final ext in VirtualMediaPicker.videoExtensions) {
        expect(VirtualMediaPicker.mimeForExtension(ext, true),
            startsWith('video/'), reason: ext);
      }
      for (final ext in VirtualMediaPicker.audioExtensions) {
        expect(VirtualMediaPicker.audioMimeForExtension(ext),
            startsWith('audio/'), reason: ext);
      }
    });

    test('the audio cap is small enough to decode into an AudioBuffer', () {
      expect(VirtualMediaPicker.audioMaxBytes, 8 * 1024 * 1024);
      expect(VirtualMediaPicker.visualMaxBytes, 24 * 1024 * 1024);
    });
  });
}
