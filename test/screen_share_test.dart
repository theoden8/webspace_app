import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/services/virtual_screen_service.dart';
import 'package:webspace/settings/screen_share.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_permission_badges.dart';

const _src = VirtualScreenSource(
  kind: 'image',
  dataUrl: 'data:image/png;base64,AAAA',
  fileName: 'slide.png',
);

void main() {
  group('screenShareModeFromJson', () {
    test('parses each known mode name', () {
      for (final mode in ScreenShareMode.values) {
        expect(screenShareModeFromJson(mode.name), mode);
      }
    });

    test('defaults to ask for absent / unknown / wrong-typed input', () {
      expect(screenShareModeFromJson(null), ScreenShareMode.ask);
      expect(screenShareModeFromJson(42), ScreenShareMode.ask);
    });

    test('there is no mode that captures the real display (SHARE-001)', () {
      expect(ScreenShareMode.values.map((m) => m.name),
          ['ask', 'virtual', 'block']);
      // A stored value naming a real grant must not resurrect one: a crafted
      // backup or a downgrade from some future build reads as `ask`.
      for (final smuggled in ['real', 'allow', 'monitor', 'screen']) {
        expect(screenShareModeFromJson(smuggled), ScreenShareMode.ask,
            reason: smuggled);
      }
    });
  });

  group('VirtualScreenSource.fromJson', () {
    test('parses a valid source', () {
      final s = VirtualScreenSource.fromJson({
        'kind': 'video',
        'dataUrl': 'data:video/mp4;base64,AAAA',
        'fileName': 'demo.mp4',
      });
      expect(s?.kind, 'video');
      expect(s?.isVideo, isTrue);
      expect(s?.fileName, 'demo.mp4');
    });

    test('defaults fileName to empty when missing', () {
      final s = VirtualScreenSource.fromJson(
          {'kind': 'image', 'dataUrl': 'data:image/png;base64,AAAA'});
      expect(s?.fileName, '');
    });

    test('rejects a non-data URL (a crafted backup cannot smuggle a fetch)',
        () {
      for (final url in [
        'https://evil.example/x.png',
        'file:///etc/passwd',
        'javascript:alert(1)',
      ]) {
        expect(
            VirtualScreenSource.fromJson({'kind': 'image', 'dataUrl': url}),
            isNull,
            reason: url);
      }
    });

    test('rejects an unknown kind, missing fields and non-maps', () {
      expect(VirtualScreenSource.fromJson(null), isNull);
      expect(VirtualScreenSource.fromJson('data:image/png;base64,AA'), isNull);
      expect(VirtualScreenSource.fromJson({'kind': 'image'}), isNull);
      expect(
          VirtualScreenSource.fromJson(
              {'kind': 'audio', 'dataUrl': 'data:audio/mpeg;base64,AA'}),
          isNull);
    });

    test('bytes decodes the base64 payload', () {
      final s = VirtualScreenSource.fromJson({
        'kind': 'image',
        'dataUrl': 'data:image/png;base64,QUJD',
        'fileName': 'a.png',
      });
      expect(s?.bytes, [65, 66, 67]);
    });
  });

  group('ScreenShareDecision.toBridgeJson', () {
    test('block carries only the mode', () {
      expect(const ScreenShareDecision.block().toBridgeJson(),
          {'mode': 'block'});
    });

    test('ask degrades to block so the shim never serves a surface', () {
      expect(const ScreenShareDecision(ScreenShareMode.ask).toBridgeJson(),
          {'mode': 'block'});
    });

    test('virtual carries the source only when present', () {
      expect(
        const ScreenShareDecision(ScreenShareMode.virtual, _src).toBridgeJson(),
        {
          'mode': 'virtual',
          'source': {'kind': 'image', 'dataUrl': 'data:image/png;base64,AAAA'},
        },
      );
      // The file name is local bookkeeping and never reaches the page.
      expect(const ScreenShareDecision(ScreenShareMode.virtual).toBridgeJson(),
          {'mode': 'virtual'});
    });
  });

  group('WebViewModel screen sharing persistence', () {
    test('an untouched site keeps byte-identical JSON', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.toJson().containsKey('screenShareMode'), isFalse);
      expect(model.toJson().containsKey('virtualScreenSource'), isFalse);
    });

    test('mode and source round-trip', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        screenShareMode: ScreenShareMode.virtual,
        virtualScreenSource: _src,
      );
      final back = WebViewModel.fromJson(model.toJson(), null);
      expect(back.screenShareMode, ScreenShareMode.virtual);
      expect(back.virtualScreenSource?.dataUrl, _src.dataUrl);
      expect(back.virtualScreenSource?.kind, 'image');
      expect(back.virtualScreenSource?.fileName, 'slide.png');
    });

    test('archive-tier sites are forced to block (SHARE-006)', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        screenShareMode: ScreenShareMode.virtual,
        virtualScreenSource: _src,
        isArchiveTier: true,
      );
      expect(model.effectiveScreenShareMode, ScreenShareMode.block);
      // The stored intent survives for when the site leaves the archive.
      expect(model.screenShareMode, ScreenShareMode.virtual);
      expect(model.virtualScreenSource, isNotNull);
    });

    test('the decision never rides the settings QR (SHARE-007)', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        screenShareMode: ScreenShareMode.virtual,
        virtualScreenSource: _src,
      );
      final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
      expect(shared.containsKey('screenShareMode'), isFalse);
      expect(shared.containsKey('virtualScreenSource'), isFalse);
    });
  });

  group('screenSharePermissionState', () {
    test('never reports a real device grant (SHARE-001)', () {
      for (final mode in ScreenShareMode.values) {
        expect(opensRealDevice(screenSharePermissionState(mode)), isFalse,
            reason: mode.name);
      }
    });

    test('projects each mode', () {
      expect(screenSharePermissionState(ScreenShareMode.ask),
          SitePermissionState.ask);
      expect(screenSharePermissionState(ScreenShareMode.virtual),
          SitePermissionState.simulated);
      expect(screenSharePermissionState(ScreenShareMode.block),
          SitePermissionState.blocked);
    });
  });

  group('drawer badge', () {
    test('a simulated surface is surfaced in the drawer', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        screenShareMode: ScreenShareMode.virtual,
        virtualScreenSource: _src,
      );
      expect(sitePermissionBadges(model),
          contains(SitePermissionBadge.virtualScreenShare));
    });

    test('ask and block carry no badge', () {
      for (final mode in [ScreenShareMode.ask, ScreenShareMode.block]) {
        final model = WebViewModel(
            initUrl: 'https://example.com', screenShareMode: mode);
        expect(sitePermissionBadges(model),
            isNot(contains(SitePermissionBadge.virtualScreenShare)),
            reason: mode.name);
      }
    });

    test('an archive-tier site shows no badge (ARCH-006)', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        screenShareMode: ScreenShareMode.virtual,
        virtualScreenSource: _src,
        isArchiveTier: true,
      );
      expect(sitePermissionBadges(model),
          isNot(contains(SitePermissionBadge.virtualScreenShare)));
    });
  });

  group('VirtualScreenService', () {
    test('accepts the same image/video shapes as the simulated camera', () {
      expect(VirtualScreenService.maxBytes, VirtualVisualMediaPicker.maxBytes);
      for (final ext in VirtualVisualMediaPicker.imageExtensions) {
        expect(VirtualVisualMediaPicker.mimeForExtension(ext, false),
            startsWith('image/'),
            reason: ext);
      }
      for (final ext in VirtualVisualMediaPicker.videoExtensions) {
        expect(VirtualVisualMediaPicker.mimeForExtension(ext, true),
            startsWith('video/'),
            reason: ext);
      }
    });
  });
}
