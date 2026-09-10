import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/microphone.dart';

void main() {
  group('a nested screen does not inherit a device grant (CAM-005 / MIC-005)',
      () {
    test('real seeds as ask', () {
      expect(
        nestedSeedMode(CameraAccessMode.real,
            real: CameraAccessMode.real, ask: CameraAccessMode.ask),
        CameraAccessMode.ask,
      );
      expect(
        nestedSeedMode(MicrophoneAccessMode.real,
            real: MicrophoneAccessMode.real, ask: MicrophoneAccessMode.ask),
        MicrophoneAccessMode.ask,
      );
    });

    test('block, virtual and ask are inherited as they are', () {
      for (final mode in [
        CameraAccessMode.block,
        CameraAccessMode.virtual,
        CameraAccessMode.ask,
      ]) {
        expect(
          nestedSeedMode(mode,
              real: CameraAccessMode.real, ask: CameraAccessMode.ask),
          mode,
        );
      }
      for (final mode in [
        MicrophoneAccessMode.block,
        MicrophoneAccessMode.virtual,
        MicrophoneAccessMode.ask,
      ]) {
        expect(
          nestedSeedMode(mode,
              real: MicrophoneAccessMode.real, ask: MicrophoneAccessMode.ask),
          mode,
        );
      }
    });

    test('InAppWebViewScreen seeds both modes through the mapping', () {
      final src = File('lib/screens/inappbrowser.dart').readAsStringSync();
      expect(src, contains('_cameraMode = nestedSeedMode(widget.cameraMode'));
      expect(src,
          contains('_microphoneMode = nestedSeedMode(widget.microphoneMode'));
    });
  });
}
