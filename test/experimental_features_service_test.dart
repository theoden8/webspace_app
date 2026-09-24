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

  test('Tor defaults on, so developer mode alone keeps opening it', () async {
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance.switchOn(ExperimentalFeature.tor),
        isTrue);
    DeveloperModeService.instance.debugSet(true);
    expect(
        ExperimentalFeaturesService.instance.isEnabled(ExperimentalFeature.tor),
        isTrue);
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

  test('link routing defaults off, even with developer mode on', () async {
    await ExperimentalFeaturesService.instance.initialize();
    DeveloperModeService.instance.debugSet(true);
    expect(
        ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.linkRouting),
        isFalse);
  });

  test('a switch persists and is read back', () async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.tor, false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kExperimentalTorKey), isFalse);

    ExperimentalFeaturesService.instance.debugSet(ExperimentalFeature.tor, true);
    await ExperimentalFeaturesService.instance.reload();
    expect(
        ExperimentalFeaturesService.instance.switchOn(ExperimentalFeature.tor),
        isFalse);
  });

  test('a wrong-typed stored value reads as the default', () async {
    SharedPreferences.setMockInitialValues({kExperimentalTorKey: 'yes'});
    await ExperimentalFeaturesService.instance.initialize();
    expect(
        ExperimentalFeaturesService.instance.switchOn(ExperimentalFeature.tor),
        isTrue);
  });
}
