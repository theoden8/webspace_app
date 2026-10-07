import 'package:webspace/settings/location.dart';

/// The state a per-site capability is in, in one word.
///
/// Every capability the app mediates reduces to one of these four, so the
/// permission screen can render one row shape and a reader can compare two
/// rows at a glance. The per-capability enums stay the source of truth: this
/// is a projection of them for display, never a stored value.
enum SitePermissionState {
  /// No decision recorded. The first request prompts, and the answer sticks.
  ///
  /// Reachable for every capture kind and protected content. Location and
  /// notifications have no first-request prompt, so they never report this.
  ask,

  /// The real device or capability reaches the page. The only state that
  /// opens hardware, which is why it is the only one drawn in the error
  /// colour.
  allowed,

  /// The page is served a file the user picked. No device is opened and no OS
  /// permission is involved.
  simulated,

  /// Requests are rejected without prompting.
  blocked,
}

/// True when [state] means a real device or capability is handed to the page,
/// as opposed to a synthetic stream or a refusal. Drives the error-colour
/// treatment shared by the permission chip and the drawer badge.
bool opensRealDevice(SitePermissionState state) =>
    state == SitePermissionState.allowed;

/// [LocationMode.off] maps to [SitePermissionState.blocked], not to a
/// pass-through state, because that is what it now does: the shim refuses
/// every request rather than leaving the platform's own geolocation reachable.
SitePermissionState locationPermissionState(LocationMode mode) =>
    switch (mode) {
      LocationMode.off => SitePermissionState.blocked,
      LocationMode.spoof => SitePermissionState.simulated,
      LocationMode.live => SitePermissionState.allowed,
    };

/// Notifications are a two-state switch today, so they never report
/// [SitePermissionState.ask].
SitePermissionState notificationPermissionState(bool enabled) =>
    enabled ? SitePermissionState.allowed : SitePermissionState.blocked;

/// `null` is the stored "no decision yet" value for protected content.
SitePermissionState protectedContentPermissionState(bool? allowed) =>
    switch (allowed) {
      null => SitePermissionState.ask,
      true => SitePermissionState.allowed,
      false => SitePermissionState.blocked,
    };
