import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    DeveloperModeService.instance.debugSet(false);
    for (final f in ExperimentalFeature.values) {
      ExperimentalFeaturesService.instance.debugSet(f, f.defaultOn);
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
    DeveloperModeService.instance.debugSet(true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteTabs),
        isFalse);
    SharedPreferences.setMockInitialValues({kExperimentalSiteTabsKey: true});
    await ExperimentalFeaturesService.instance.reload();
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteTabs),
        isTrue);
  });

  test('Tor graduated: it has no switch (TOR-007)', () {
    expect(
        ExperimentalFeature.values.map((f) => f.prefKey),
        isNot(contains('experimentalTor')),
        reason: 'a graduated feature removes its switch and stops reading '
            'this gate (DEVTOOLS-011)');
  });

  test('the proxy router defaults on, so developer mode alone keeps it',
      () async {
    await ExperimentalFeaturesService.instance.initialize();
    DeveloperModeService.instance.debugSet(true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.proxyRouter),
        isTrue);
  });

  test('site icons only defaults off, so developer mode alone keeps the '
      'public icon services', () async {
    await ExperimentalFeaturesService.instance.initialize();
    DeveloperModeService.instance.debugSet(true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteIconsOnly),
        isFalse);
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.siteIconsOnly, true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.siteIconsOnly),
        isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kExperimentalSiteIconsOnlyKey), isTrue);
  });

  test('a switch persists and is read back', () async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.proxyRouter, false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kExperimentalProxyRouterKey), isFalse);

    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.proxyRouter, true);
    await ExperimentalFeaturesService.instance.reload();
    expect(
        ExperimentalFeaturesService.instance
            .switchOn(ExperimentalFeature.proxyRouter),
        isFalse);
  });

  test('a wrong-typed stored value reads as the default', () async {
    SharedPreferences.setMockInitialValues({kExperimentalProxyRouterKey: 'yes'});
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance
            .switchOn(ExperimentalFeature.proxyRouter),
        isTrue);
  });
}
