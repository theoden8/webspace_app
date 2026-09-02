import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/screen_share.dart';

/// The state a per-site capability is in, in one word.
///
/// Every capability the app mediates reduces to one of these four, so the
/// permission screen can render one row shape and a reader can compare two
/// rows at a glance. The per-capability enums stay the source of truth: this
/// is a projection of them for display, never a stored value.
///
/// The vocabulary matters more than it looks. Before it, the same concept was
/// spelled four ways across the settings screen ("Always allow" / "Simulated
/// camera" / "Audio file" / "Live"), and [LocationMode.off] was labelled "Off"
/// while meaning pass-through.
enum SitePermissionState {
  /// No decision recorded. The first request prompts, and the answer sticks.
  ///
  /// Reachable for camera, microphone and protected content. Location and
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

SitePermissionState cameraPermissionState(CameraAccessMode mode) =>
    switch (mode) {
      CameraAccessMode.ask => SitePermissionState.ask,
      CameraAccessMode.real => SitePermissionState.allowed,
      CameraAccessMode.virtual => SitePermissionState.simulated,
      CameraAccessMode.block => SitePermissionState.blocked,
    };

/// There is no real-microphone mode: [MicrophoneAccessMode] has no `real`
/// value, the native layer denies audio capture outright, and no platform
/// manifest declares a recording permission. So this never returns
/// [SitePermissionState.allowed].
SitePermissionState microphonePermissionState(MicrophoneAccessMode mode) =>
    switch (mode) {
      MicrophoneAccessMode.ask => SitePermissionState.ask,
      MicrophoneAccessMode.virtual => SitePermissionState.simulated,
      MicrophoneAccessMode.block => SitePermissionState.blocked,
    };

/// There is no real-screen mode either, and for a stronger reason than the
/// microphone's: a display capture is whole-surface, so granting one would
/// hand the site every OTHER site in the webspace. So this never returns
/// [SitePermissionState.allowed].
SitePermissionState screenSharePermissionState(ScreenShareMode mode) =>
    switch (mode) {
      ScreenShareMode.ask => SitePermissionState.ask,
      ScreenShareMode.virtual => SitePermissionState.simulated,
      ScreenShareMode.block => SitePermissionState.blocked,
    };

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
