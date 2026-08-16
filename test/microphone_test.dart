import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/virtual_microphone_service.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  group('microphoneAccessModeFromJson', () {
    test('parses each known mode name', () {
      for (final mode in MicrophoneAccessMode.values) {
        expect(microphoneAccessModeFromJson(mode.name), mode);
      }
    });

    test('defaults to ask for absent / unknown / wrong-typed input', () {
      expect(microphoneAccessModeFromJson(null), MicrophoneAccessMode.ask);
      expect(microphoneAccessModeFromJson('real'), MicrophoneAccessMode.ask);
      expect(microphoneAccessModeFromJson(42), MicrophoneAccessMode.ask);
    });

    test('there is no mode that opens the real device (MIC-001)', () {
      expect(MicrophoneAccessMode.values.map((m) => m.name),
          ['ask', 'virtual', 'block']);
    });
  });

  group('VirtualMicrophoneSource.fromJson', () {
    test('parses a valid source', () {
      final s = VirtualMicrophoneSource.fromJson({
        'dataUrl': 'data:audio/mpeg;base64,AAAA',
        'fileName': 'tone.mp3',
      });
      expect(s?.dataUrl, 'data:audio/mpeg;base64,AAAA');
      expect(s?.fileName, 'tone.mp3');
    });

    test('defaults fileName to empty when missing', () {
      final s = VirtualMicrophoneSource.fromJson(
          {'dataUrl': 'data:audio/mpeg;base64,AAAA'});
      expect(s?.fileName, '');
    });

    test('rejects a non-data URL (crafted backup can not smuggle a fetch)', () {
      for (final url in [
        'https://evil.example/x.mp3',
        'file:///etc/passwd',
        'javascript:alert(1)',
      ]) {
        expect(VirtualMicrophoneSource.fromJson({'dataUrl': url}), isNull,
            reason: url);
      }
    });

    test('rejects missing fields and non-maps', () {
      expect(VirtualMicrophoneSource.fromJson(null), isNull);
      expect(VirtualMicrophoneSource.fromJson('data:audio/mpeg;base64,AA'),
          isNull);
      expect(VirtualMicrophoneSource.fromJson({'fileName': 'x.mp3'}), isNull);
    });

    test('bytes decodes the base64 payload', () {
      final s = VirtualMicrophoneSource.fromJson({
        'dataUrl': 'data:audio/wav;base64,QUJD',
        'fileName': 'a.wav',
      });
      expect(s?.bytes, [65, 66, 67]);
    });

    test('bytes returns null for a payload with no base64 marker', () {
      final s = VirtualMicrophoneSource.fromJson(
          {'dataUrl': 'data:audio/wav,plain', 'fileName': 'a.wav'});
      expect(s?.bytes, isNull);
    });
  });

  group('MicrophoneDecision.toBridgeJson', () {
    test('block carries only the mode', () {
      expect(const MicrophoneDecision.block().toBridgeJson(),
          {'mode': 'block'});
    });

    test('ask degrades to block so the shim never serves a stream', () {
      expect(const MicrophoneDecision(MicrophoneAccessMode.ask).toBridgeJson(),
          {'mode': 'block'});
    });

    test('virtual carries the source only when present', () {
      const src = VirtualMicrophoneSource(
          dataUrl: 'data:audio/mpeg;base64,AAAA', fileName: 'tone.mp3');
      expect(
        const MicrophoneDecision(MicrophoneAccessMode.virtual, src)
            .toBridgeJson(),
        {
          'mode': 'virtual',
          'source': {'dataUrl': 'data:audio/mpeg;base64,AAAA'},
        },
      );
      // The file name is local bookkeeping and never reaches the page.
      expect(
          const MicrophoneDecision(MicrophoneAccessMode.virtual)
              .toBridgeJson(),
          {'mode': 'virtual'});
    });
  });

  group('WebViewModel microphone persistence', () {
    const src = VirtualMicrophoneSource(
        dataUrl: 'data:audio/mpeg;base64,AAAA', fileName: 'tone.mp3');

    test('an untouched site keeps byte-identical JSON', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.toJson().containsKey('microphoneMode'), isFalse);
      expect(model.toJson().containsKey('virtualMicrophoneSource'), isFalse);
    });

    test('mode and source round-trip', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        microphoneMode: MicrophoneAccessMode.virtual,
        virtualMicrophoneSource: src,
      );
      final back = WebViewModel.fromJson(model.toJson(), null);
      expect(back.microphoneMode, MicrophoneAccessMode.virtual);
      expect(back.virtualMicrophoneSource?.dataUrl, src.dataUrl);
      expect(back.virtualMicrophoneSource?.fileName, 'tone.mp3');
    });

    test('archive-tier sites are forced to block (MIC-006)', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        microphoneMode: MicrophoneAccessMode.virtual,
        virtualMicrophoneSource: src,
        isArchiveTier: true,
      );
      expect(model.effectiveMicrophoneMode, MicrophoneAccessMode.block);
      // The stored intent survives for when the site leaves the archive.
      expect(model.microphoneMode, MicrophoneAccessMode.virtual);
      expect(model.virtualMicrophoneSource, isNotNull);
    });

    test('the decision never rides the settings QR (MIC-007)', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        microphoneMode: MicrophoneAccessMode.virtual,
        virtualMicrophoneSource: src,
      );
      final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
      expect(shared.containsKey('microphoneMode'), isFalse);
      expect(shared.containsKey('virtualMicrophoneSource'), isFalse);
    });
  });

  group('VirtualMicrophoneService', () {
    test('every accepted extension maps to an audio MIME type', () {
      for (final ext in ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus',
        'flac', 'weba']) {
        expect(VirtualMicrophoneService.mimeForExtension(ext),
            startsWith('audio/'),
            reason: ext);
      }
    });

    test('the cap is small enough to decode into an AudioBuffer', () {
      expect(VirtualMicrophoneService.maxBytes, 8 * 1024 * 1024);
    });
  });
}
