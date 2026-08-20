import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/site_permission_state.dart';

void main() {
  group('SitePermissionState projection', () {
    test('camera covers all four states', () {
      expect(cameraPermissionState(CameraAccessMode.ask), SitePermissionState.ask);
      expect(cameraPermissionState(CameraAccessMode.real),
          SitePermissionState.allowed);
      expect(cameraPermissionState(CameraAccessMode.virtual),
          SitePermissionState.simulated);
      expect(cameraPermissionState(CameraAccessMode.block),
          SitePermissionState.blocked);
    });

    test('microphone can never report allowed', () {
      // Not a property of this mapping so much as of the app: there is no
      // real-microphone mode, the native layer denies audio capture, and no
      // platform manifest declares a recording permission. If a `real` value
      // is ever added to MicrophoneAccessMode this test is where it surfaces.
      for (final mode in MicrophoneAccessMode.values) {
        expect(microphonePermissionState(mode),
            isNot(SitePermissionState.allowed),
            reason: '$mode must not project to allowed');
      }
    });

    test('location off is blocked, not a pass-through state', () {
      // LOC-OFF-001: `off` refuses. Projecting it to anything softer would put
      // the interface back to describing a pass-through that no longer exists.
      expect(locationPermissionState(LocationMode.off),
          SitePermissionState.blocked);
      expect(locationPermissionState(LocationMode.spoof),
          SitePermissionState.simulated);
      expect(locationPermissionState(LocationMode.live),
          SitePermissionState.allowed);
    });

    test('notifications and protected content project their stored shapes', () {
      expect(notificationPermissionState(true), SitePermissionState.allowed);
      expect(notificationPermissionState(false), SitePermissionState.blocked);
      expect(protectedContentPermissionState(null), SitePermissionState.ask);
      expect(protectedContentPermissionState(true), SitePermissionState.allowed);
      expect(
          protectedContentPermissionState(false), SitePermissionState.blocked);
    });

    test('only allowed counts as opening a real device', () {
      // Drives the error-colour treatment on both the chip and the drawer
      // badge, so a wrong answer here misreports a site's posture on two
      // surfaces at once.
      for (final state in SitePermissionState.values) {
        expect(opensRealDevice(state), state == SitePermissionState.allowed,
            reason: '$state');
      }
    });

    test('every mode of every capability projects to some state', () {
      // Guards the exhaustiveness the switch expressions give us today: adding
      // an enum value without deciding its state fails to compile, and this
      // catches the case where someone adds a default arm instead.
      expect(CameraAccessMode.values.map(cameraPermissionState).toSet().length,
          4);
      expect(
          MicrophoneAccessMode.values.map(microphonePermissionState).toSet(),
          {
            SitePermissionState.ask,
            SitePermissionState.simulated,
            SitePermissionState.blocked,
          });
      expect(LocationMode.values.map(locationPermissionState).toSet().length, 3);
    });
  });
}
