import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/page_shim.dart';

void main() {
  test('every shim ends in the evaluator sentinel', () {
    // The evaluator returns the IIFE's value otherwise, which the platform
    // channel cannot serialize for some shapes.
    final s = pageShim(ShimGroup.doNotTrack, js: '(function(){})();');
    expect(s.source, '(function(){})();\n;null;');
    expect(s.groupName, 'do_not_track');
  });

  test('a group\'s frames and timing map onto the plugin flags', () {
    for (final group in ShimGroup.values) {
      final s = pageShim(group, js: 'x');
      expect(s.groupName, group.groupName);
      expect(s.forMainFrameOnly, group.frames == ShimFrames.top,
          reason: group.name);
      expect(
          s.injectionTime,
          switch (group.at) {
            ShimTime.start => inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
            ShimTime.end => inapp.UserScriptInjectionTime.AT_DOCUMENT_END,
          },
          reason: group.name);
    }
  });

  test('a group name names one group, the user scripts at either time aside',
      () {
    final byName = <String, List<ShimGroup>>{};
    for (final group in ShimGroup.values) {
      (byName[group.groupName] ??= []).add(group);
    }
    for (final MapEntry(:key, :value) in byName.entries) {
      expect(value.length,
          key == 'user_scripts' ? 2 : 1, reason: key);
    }
  });

  test('the shims that keep values from a page reach every frame '
      '(PASSKEY-013, SHARE-005)', () {
    // A cross-origin iframe would otherwise read the real location, language,
    // canvas or user agent beside the spoofed top document.
    for (final group in [
      ShimGroup.antiFingerprinting,
      ShimGroup.locationSpoof,
      ShimGroup.languageOverride,
      ShimGroup.uaIdentity,
      ShimGroup.desktopMode,
      ShimGroup.webglKillSwitch,
      ShimGroup.worker,
      ShimGroup.passkeyBlock,
      ShimGroup.targetBlankRewrite,
    ]) {
      expect(group.frames, ShimFrames.all, reason: group.name);
      expect(group.at, ShimTime.start, reason: group.name);
    }
    // SHARE-005: the share reaches the top document only.
    expect(ShimGroup.screenShare.frames, ShimFrames.top);
  });

  test('only the theme and the OS text size are replaced on a live view', () {
    expect({for (final l in LiveShim.values) l.group},
        {ShimGroup.themeColorScheme, ShimGroup.systemTextZoom});
  });
}
