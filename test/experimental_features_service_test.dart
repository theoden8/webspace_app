import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/settings/app_prefs.dart';

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

  test('Site tabs default off: they are new (TAB-012)', () async {
    await ExperimentalFeaturesService.instance.initialize();
    DeveloperModeService.instance.debugSet(on: true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteTabs),
        isFalse);
    SharedPreferences.setMockInitialValues({AppPref.experimentalSiteTabs.key: true});
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteTabs),
        isTrue);
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

  test('the proxy router defaults on, so developer mode alone keeps it',
      () async {
    await ExperimentalFeaturesService.instance.initialize();
    DeveloperModeService.instance.debugSet(on: true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.proxyRouter),
        isTrue);
  });

  test('site icons only defaults off, so developer mode alone keeps the '
      'public icon services', () async {
    await ExperimentalFeaturesService.instance.initialize();
    DeveloperModeService.instance.debugSet(on: true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteIconsOnly),
        isFalse);
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.siteIconsOnly, on: true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteIconsOnly),
        isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.experimentalSiteIconsOnly.key), isTrue);
  });

  test('a switch persists and is read back', () async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.proxyRouter, on: false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.experimentalProxyRouter.key), isFalse);

    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.proxyRouter, on: true);
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance
            .switchOn(ExperimentalFeature.proxyRouter),
        isFalse);
  });

  test('a wrong-typed stored value reads as the default', () async {
    SharedPreferences.setMockInitialValues({AppPref.experimentalProxyRouter.key: 'yes'});
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance
            .switchOn(ExperimentalFeature.proxyRouter),
        isTrue);
  });
}
