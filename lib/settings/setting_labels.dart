/// Display names for the per-site mode enums. Exhaustive switches, so a new
/// mode does not compile until it has a name everywhere it is shown.
library;

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/settings/user_script.dart';

extension ExternalLinkModeLabel on ExternalLinkMode {
  String label(AppLocalizations loc) => switch (this) {
    ExternalLinkMode.inApp => loc.siteSettingsExternalLinksInApp,
    ExternalLinkMode.browser => loc.siteSettingsExternalLinksBrowser,
    ExternalLinkMode.block => loc.siteSettingsExternalLinksBlock,
  };

  /// How a site summary names the mode; null for the default, which a
  /// summary leaves out.
  String? summary(AppLocalizations loc) => switch (this) {
    ExternalLinkMode.inApp => null,
    ExternalLinkMode.browser => loc.siteSettingsExternalLinksInBrowser,
    ExternalLinkMode.block => loc.siteSettingsExternalLinksBlockedSummary,
  };
}

extension WebRtcPolicyLabel on WebRtcPolicy {
  String label(AppLocalizations loc) => switch (this) {
    WebRtcPolicy.defaultPolicy => loc.siteSettingsWebRtcDefault,
    WebRtcPolicy.relayOnly => loc.siteSettingsWebRtcRelayOnly,
    WebRtcPolicy.disabled => loc.siteSettingsWebRtcDisabled,
  };

  String? summary(AppLocalizations loc) => switch (this) {
    WebRtcPolicy.defaultPolicy => null,
    WebRtcPolicy.relayOnly ||
    WebRtcPolicy.disabled => loc.networkSummaryWebRtc(label(loc)),
  };
}

extension CaptureModeLabel on CaptureMode {
  String label(AppLocalizations loc) => switch (this) {
    CameraAccessMode.ask => loc.siteSettingsCameraAccessAsk,
    CameraAccessMode.real => loc.siteSettingsCameraAccessAllow,
    CameraAccessMode.virtual => loc.siteSettingsCameraAccessVirtual,
    CameraAccessMode.block => loc.siteSettingsCameraAccessBlock,
    MicrophoneAccessMode.ask => loc.siteSettingsMicrophoneAccessAsk,
    MicrophoneAccessMode.real => loc.siteSettingsMicrophoneAccessAllow,
    MicrophoneAccessMode.virtual => loc.siteSettingsMicrophoneAccessVirtual,
    MicrophoneAccessMode.block => loc.siteSettingsMicrophoneAccessBlock,
    ScreenShareMode.ask => loc.siteSettingsScreenShareAsk,
    ScreenShareMode.virtual => loc.siteSettingsScreenShareVirtual,
    ScreenShareMode.block => loc.siteSettingsScreenShareBlock,
  };
}

/// A capture kind's copy: its settings row, its first-request popup, and what
/// the picker says about a file it cannot use.
typedef CaptureText = ({
  String title,
  String hint,
  String noSource,
  String chooseSource,
  String promptTitle,
  String Function(String origin) promptBody,
  String useFile,
  String tooLarge,
  String unreadable,
  // Why the Allowed row is greyed, for a kind with no real mode.
  String? neverReal,
});

extension CaptureKindText on CaptureKind {
  CaptureText text(AppLocalizations loc) => switch (this) {
    CaptureKind.camera => (
      title: loc.siteSettingsCameraAccess,
      hint: loc.siteSettingsCameraAccessHint,
      noSource: loc.siteSettingsCameraAccessNoSource,
      chooseSource: loc.siteSettingsCameraAccessChooseSource,
      promptTitle: loc.homeCameraAccessTitle,
      promptBody: loc.homeCameraAccessBody,
      useFile: loc.homeCameraUseFileAction,
      tooLarge: loc.homeCameraSourceTooLarge,
      unreadable: loc.homeCameraSourceError,
      neverReal: null,
    ),
    CaptureKind.microphone => (
      title: loc.siteSettingsMicrophoneAccess,
      hint: loc.siteSettingsMicrophoneAccessHint,
      noSource: loc.siteSettingsMicrophoneAccessNoSource,
      chooseSource: loc.siteSettingsMicrophoneAccessChooseSource,
      promptTitle: loc.homeMicrophoneAccessTitle,
      promptBody: loc.homeMicrophoneAccessBody,
      useFile: loc.homeMicrophoneUseFileAction,
      tooLarge: loc.homeMicrophoneSourceTooLarge,
      unreadable: loc.homeMicrophoneSourceError,
      neverReal: null,
    ),
    CaptureKind.screenShare => (
      title: loc.siteSettingsScreenShare,
      hint: loc.siteSettingsScreenShareHint,
      noSource: loc.siteSettingsScreenShareNoSource,
      chooseSource: loc.siteSettingsScreenShareChooseSource,
      promptTitle: loc.homeScreenShareTitle,
      promptBody: loc.homeScreenShareBody,
      useFile: loc.homeScreenShareUseFileAction,
      tooLarge: loc.homeScreenShareSourceTooLarge,
      unreadable: loc.homeScreenShareSourceError,
      neverReal: loc.permissionScreenShareNeverReal,
    ),
  };
}

extension LocationModeLabel on LocationMode {
  String label(AppLocalizations loc) => switch (this) {
    LocationMode.live => loc.siteSettingsLocationLive,
    LocationMode.spoof => loc.siteSettingsLocationStatic,
    LocationMode.off => loc.siteSettingsLocationOff,
  };
}

extension LocationGranularityLabel on LocationGranularity {
  String label(AppLocalizations loc) => switch (this) {
    LocationGranularity.gps => loc.siteSettingsLocationProviderGps,
    LocationGranularity.approximate => loc.siteSettingsLocationApproximate,
    LocationGranularity.gsm => loc.siteSettingsLocationProviderGsm,
  };

  String description(AppLocalizations loc) => switch (this) {
    LocationGranularity.gps => loc.siteSettingsLocationGranularityGps,
    LocationGranularity.approximate =>
      loc.siteSettingsLocationGranularityApproximate,
    LocationGranularity.gsm => loc.siteSettingsLocationGranularityGsm,
  };
}

extension SitePermissionStateLabel on SitePermissionState {
  String label(AppLocalizations loc) => switch (this) {
    SitePermissionState.ask => loc.permissionStateAsk,
    SitePermissionState.allowed => loc.permissionStateAllowed,
    SitePermissionState.simulated => loc.permissionStateSimulated,
    SitePermissionState.blocked => loc.permissionStateBlocked,
  };
}

extension ScopedSwitchLabel on Scoped<bool> {
  /// [appValue] is what following the app would give the site.
  String label(AppLocalizations loc, {required bool appValue}) =>
      switch (this) {
        FollowApp() => loc.settingFollowsApp(_onOff(loc, appValue)),
        Own(:final value) => _onOff(loc, value),
      };
}

String _onOff(AppLocalizations loc, bool on) =>
    on ? loc.settingOn : loc.settingOff;

extension UserScriptInjectionTimeLabel on UserScriptInjectionTime {
  String label(AppLocalizations loc) => switch (this) {
    UserScriptInjectionTime.atDocumentStart => loc.userScriptsAtDocumentStart,
    UserScriptInjectionTime.atDocumentEnd => loc.userScriptsAtDocumentEnd,
  };
}
