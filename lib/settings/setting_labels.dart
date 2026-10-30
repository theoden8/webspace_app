/// Display names for the per-site mode enums. Exhaustive switches, so a new
/// mode does not compile until it has a name everywhere it is shown.
library;

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/settings/web_view_theme.dart';

extension ExternalLinkModeLabel on ExternalLinkMode {
  Localized label(AppLocalizations loc) => switch (this) {
    ExternalLinkMode.inApp => loc.siteSettingsExternalLinksInApp,
    ExternalLinkMode.browser => loc.siteSettingsExternalLinksBrowser,
    ExternalLinkMode.block => loc.siteSettingsExternalLinksBlock,
  };

  /// How a site summary names the mode; null for the default, which a
  /// summary leaves out.
  Localized? summary(AppLocalizations loc) => switch (this) {
    ExternalLinkMode.inApp => null,
    ExternalLinkMode.browser => loc.siteSettingsExternalLinksInBrowser,
    ExternalLinkMode.block => loc.siteSettingsExternalLinksBlockedSummary,
  };
}

extension WebRtcPolicyLabel on WebRtcPolicy {
  Localized label(AppLocalizations loc) => switch (this) {
    WebRtcPolicy.defaultPolicy => loc.siteSettingsWebRtcDefault,
    WebRtcPolicy.relayOnly => loc.siteSettingsWebRtcRelayOnly,
    WebRtcPolicy.disabled => loc.siteSettingsWebRtcDisabled,
  };

  Localized? summary(AppLocalizations loc) => switch (this) {
    WebRtcPolicy.defaultPolicy => null,
    WebRtcPolicy.relayOnly ||
    WebRtcPolicy.disabled => loc.networkSummaryWebRtc(label(loc)),
  };
}

extension CaptureModeLabel on CaptureMode {
  Localized label(AppLocalizations loc) => switch (this) {
    CameraAccessMode.ask => loc.siteSettingsCameraAccessAsk,
    CameraAccessMode.real => loc.siteSettingsCameraAccessAllow,
    CameraAccessMode.virtual => loc.siteSettingsCameraAccessVirtual,
    CameraAccessMode.block => loc.siteSettingsCameraAccessBlock,
    MicrophoneAccessMode.ask => loc.siteSettingsMicrophoneAccessAsk,
    MicrophoneAccessMode.real => loc.siteSettingsMicrophoneAccessAllow,
    MicrophoneAccessMode.virtual => loc.siteSettingsMicrophoneAccessVirtual,
    MicrophoneAccessMode.block => loc.siteSettingsMicrophoneAccessBlock,
    ScreenShareMode.ask => loc.siteSettingsScreenShareAsk,
    ScreenShareMode.real => loc.siteSettingsScreenShareAllow,
    ScreenShareMode.virtual => loc.siteSettingsScreenShareVirtual,
    ScreenShareMode.block => loc.siteSettingsScreenShareBlock,
  };
}

/// A capture kind's copy: its settings row, its first-request popup, and what
/// the picker says about a file it cannot use.
typedef CaptureText = ({
  Localized title,
  Localized hint,
  Localized noSource,
  Localized chooseSource,
  Localized promptTitle,
  Localized Function(String origin) promptBody,
  Localized useFile,
  Localized tooLarge,
  Localized unreadable,
  // Why the Allowed row is greyed where the real mode is not offered.
  Localized? realUnavailable,
  // What the user is told before setting the real mode from settings, for a
  // kind whose real grant shows more than the site itself.
  Localized? allowWarning,
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
      realUnavailable: null,
      allowWarning: null,
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
      realUnavailable: null,
      allowWarning: null,
    ),
    CaptureKind.screenShare => (
      title: loc.siteSettingsScreenShare,
      hint: loc.siteSettingsScreenShareRealHint,
      noSource: loc.siteSettingsScreenShareNoSource,
      chooseSource: loc.siteSettingsScreenShareChooseSource,
      promptTitle: loc.homeScreenShareTitle,
      promptBody: realOffered
          ? loc.homeScreenShareAllowBody
          : loc.homeScreenShareFileOnlyBody,
      useFile: loc.homeScreenShareUseFileAction,
      tooLarge: loc.homeScreenShareSourceTooLarge,
      unreadable: loc.homeScreenShareSourceError,
      realUnavailable: loc.permissionScreenShareUnavailable,
      allowWarning: loc.siteSettingsScreenShareAllowWarning,
    ),
  };
}

extension LocationModeLabel on LocationMode {
  Localized label(AppLocalizations loc) => switch (this) {
    LocationMode.live => loc.siteSettingsLocationLive,
    LocationMode.spoof => loc.siteSettingsLocationStatic,
    LocationMode.off => loc.siteSettingsLocationOff,
  };
}

extension LocationGranularityLabel on LocationGranularity {
  Localized label(AppLocalizations loc) => switch (this) {
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
  Localized label(AppLocalizations loc) => switch (this) {
    SitePermissionState.ask => loc.permissionStateAsk,
    SitePermissionState.allowed => loc.permissionStateAllowed,
    SitePermissionState.simulated => loc.permissionStateSimulated,
    SitePermissionState.blocked => loc.permissionStateBlocked,
  };
}

extension WebViewThemeLabel on WebViewTheme {
  Localized label(AppLocalizations loc) => switch (this) {
    WebViewTheme.light => loc.appSettingsThemeLight,
    WebViewTheme.dark => loc.appSettingsThemeDark,
    WebViewTheme.system => loc.appSettingsThemeSystem,
  };
}

extension ScopedThemeLabel on Scoped<WebViewTheme> {
  /// [appValue] is the app's theme, which following it gives the site.
  Localized label(AppLocalizations loc, {required WebViewTheme appValue}) =>
      switch (this) {
        FollowApp() => loc.settingFollowsApp(appValue.label(loc)),
        Own(:final value) => value.label(loc),
      };
}

extension UserScriptInjectionTimeLabel on UserScriptInjectionTime {
  Localized label(AppLocalizations loc) => switch (this) {
    UserScriptInjectionTime.atDocumentStart => loc.userScriptsAtDocumentStart,
    UserScriptInjectionTime.atDocumentEnd => loc.userScriptsAtDocumentEnd,
  };
}
