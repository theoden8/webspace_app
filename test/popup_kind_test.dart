import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/scoped.dart';

const _site = 'https://claude.ai';
const _google =
    'https://accounts.google.com/o/oauth2/v2/auth?display=popup&redirect_uri=gis_transform';
const _challenge = 'https://challenges.cloudflare.com/turnstile/v0/api.js';

void main() {
  test('NESTED-014: a sign-in URL is an https page on a provider\'s host', () {
    for (final (url, expected) in [
      (_google, true),
      ('https://accounts.youtube.com/accounts/SetSID', true),
      ('https://appleid.apple.com/auth/authorize', true),
      ('https://login.microsoftonline.com/common/oauth2/v2.0/authorize', true),
      ('https://github.com/login/oauth/authorize', true),
      ('http://accounts.google.com/o/oauth2/v2/auth', false),
      ('https://accounts.google.com.evil.example/', false),
      ('https://notgithub.com/login', false),
      ('https://www.google.com/', false),
      ('', false),
    ]) {
      expect(PopupKind.isSignInUrl(url), expected, reason: url);
    }
  });

  // Android names no URL for a window a script opened (the plugin reads it
  // off the tapped link), so an empty one is a sign-in popup whose own rule
  // judges its first page.
  test('NESTED-014: a window opens a popup by its URL and the switch', () {
    for (final (url, switchOn, expected) in [
      (_challenge, false, PopupKind.verification),
      (_challenge, true, PopupKind.verification),
      (_google, false, null),
      (_google, true, PopupKind.signIn),
      ('', false, null),
      ('', true, PopupKind.signIn),
      ('https://ads.example/landing', true, null),
      ('$_site/settings', true, null),
    ]) {
      expect(
        PopupKind.forWindow(url, siteUrl: _site, signInPopups: switchOn),
        expected,
        reason: 'url=$url switch=$switchOn',
      );
    }
  });

  // iOS, macOS and Linux offer sign-in popups with developer mode off; on
  // Android the experiment offers them. Where offered, the site's own switch decides, or
  // the app's while the site follows it.
  test('NESTED-014: a site opens sign-in popups where the host offers them '
      "and its switch, or the app's, is on", () {
    expect(PopupKind.signInExperimental, hostIsAndroid,
        reason: 'they graduated everywhere but Android (DEVTOOLS-011)');
    addTearDown(() {
      PopupKind.debugSignInExperimental = null;
      DeveloperModeService.instance.debugSet(on: false);
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.signInPopups, on: false);
      AppPref.signInPopups.debugValue = true;
    });
    const follow = FollowApp<bool>();
    for (final (experimental, experimentOn, app, site, expected)
        in <(bool, bool, bool, Scoped<bool>, bool)>[
      (false, false, true, follow, true),
      (false, false, false, follow, false),
      (false, false, false, const Own(true), true),
      (false, false, true, const Own(false), false),
      (true, false, true, follow, false),
      (true, false, true, const Own(true), false),
      (true, true, true, follow, true),
      (true, true, false, follow, false),
      (true, true, true, const Own(false), false),
    ]) {
      PopupKind.debugSignInExperimental = experimental;
      DeveloperModeService.instance.debugSet(on: experimentOn);
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.signInPopups, on: experimentOn);
      AppPref.signInPopups.debugValue = app;
      expect(PopupKind.signInOffered, !experimental || experimentOn);
      expect(PopupKind.signInOpens(choice: site), expected,
          reason: 'experimental=$experimental experimentOn=$experimentOn '
              'app=$app site=$site');
    }
  });

  test('NESTED-014: a sign-in popup may show its provider, a verification '
      'popup only a challenge', () {
    for (final (kind, url, expected) in [
      (PopupKind.verification, _challenge, true),
      (PopupKind.verification, _google, false),
      (PopupKind.signIn, _google, true),
      (PopupKind.signIn, _challenge, true),
      (PopupKind.signIn, 'https://ads.example/landing', false),
    ]) {
      expect(kind.showsOffSite(url, siteUrl: _site), expected,
          reason: '$kind $url');
    }
  });
}
