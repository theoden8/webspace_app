import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/site_permission_state.dart';

void main() {
  group('SitePermissionState projection', () {
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
      expect(notificationPermissionState(enabled: true),
          SitePermissionState.allowed);
      expect(notificationPermissionState(enabled: false),
          SitePermissionState.blocked);
      expect(protectedContentPermissionState(allowed: null),
          SitePermissionState.ask);
      expect(protectedContentPermissionState(allowed: true),
          SitePermissionState.allowed);
      expect(protectedContentPermissionState(allowed: false),
          SitePermissionState.blocked);
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

    test('location projects each mode to its own state', () {
      expect(LocationMode.values.map(locationPermissionState).toSet().length, 3);
    });
  });
}
