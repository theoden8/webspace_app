import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_tor.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    DeveloperModeService.instance.debugSet(on: false);
    for (final f in ExperimentalFeature.values) {
      ExperimentalFeaturesService.instance.debugSet(f, on: f.pref.fallback);
    }
  });

  test('a feature needs both developer mode and its own switch', () {
    for (final (dev, on, expected) in [
      (false, false, false),
      (false, true, false),
      (true, false, false),
      (true, true, true),
    ]) {
      expect(
        experimentalFeatureEnabled(developerMode: dev, switchOn: on),
        expected,
        reason: 'developerMode=$dev switchOn=$on',
      );
    }
  });

  test('Tor graduated: it has no switch (TOR-007)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalTor')),
        reason: 'a graduated feature removes its switch and stops reading '
            'this gate (DEVTOOLS-011)');
  });

  test('Saved proxies graduated: they have no switch (PROXY-030)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalProxyLibrary')),
        reason: 'a graduated feature removes its switch and stops reading '
            'this gate (DEVTOOLS-011)');
  });

  test('Tor (external) graduated: its switch ignores developer mode '
      '(TOR-025)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains(AppPref.externalTor.key)),
        reason: 'a graduated feature removes its switch and stops reading '
            'this gate (DEVTOOLS-011)');
    addTearDown(() => AppPref.externalTor.debugValue = false);
    AppPref.externalTor.debugValue = true;
    DeveloperModeService.instance.debugSet(on: false);
    expect(ExternalTorSettings.chosen, isTrue);
  });

  test('Site tabs graduated: they have no switch (TAB-012)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalSiteTabs')),
        reason: 'a graduated feature removes its switch and stops reading '
            'this gate (DEVTOOLS-011)');
  });

  test('Site icons only graduated: it has no switch (ICON-014)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalSiteIconsOnly')),
        reason: 'a graduated feature removes its switch and stops reading '
            'this gate (DEVTOOLS-011)');
  });

  test('WebKit content blocking graduated: it has no switch (CB-020)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalContentRuleLists')),
        reason: "the lists attach whenever a site's content blocker runs, on "
            'Linux as on iOS and macOS (DEVTOOLS-011)');
  });

  test('Sign-in popups graduated: they have no switch (NESTED-014)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalSignInPopups')),
        reason: "the app's and each site's Sign-in popups switches decide, on "
            'every platform (DEVTOOLS-011)');
  });

  test('The tray icon graduated: it has no switch (NOTIF-019)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalDesktopTray')),
        reason: 'Keep running when closed alone shows the tray, on macOS as '
            'on Linux (DEVTOOLS-011)');
  });

  test('Proxy router graduated: its switch is not an experiment (PROXY-013)',
      () {
    expect(
        ExperimentalFeature.values.map((f) => f.pref.key),
        isNot(contains('experimentalProxyRouter')),
        reason: 'a graduated feature removes its switch and stops reading '
            'this gate (DEVTOOLS-011)');
  });

  test('a switch persists and is read back', () async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.textureRendering, on: true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.experimentalTextureRendering.key), isTrue);

    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.textureRendering, on: false);
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance
            .switchOn(ExperimentalFeature.textureRendering),
        isTrue);
  });

  test('folder library defaults off and persists its opt-in', () async {
    await ExperimentalFeaturesService.instance.initialize();
    DeveloperModeService.instance.debugSet(on: true);
    expect(ExperimentalFeaturesService.instance.isEnabled(ExperimentalFeature.folderLibrary), isFalse);
    await ExperimentalFeaturesService.instance.setSwitch(ExperimentalFeature.folderLibrary, on: true);
    expect(ExperimentalFeaturesService.instance.isEnabled(ExperimentalFeature.folderLibrary), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.experimentalFolderLibrary.key), isTrue);
    DeveloperModeService.instance.debugSet(on: false);
    expect(ExperimentalFeaturesService.instance.isEnabled(ExperimentalFeature.folderLibrary), isFalse);
  });

  test('a wrong-typed stored value reads as the default', () async {
    SharedPreferences.setMockInitialValues(
        {AppPref.experimentalTextureRendering.key: 'yes'});
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance
            .switchOn(ExperimentalFeature.textureRendering),
        isFalse);
  });
}
