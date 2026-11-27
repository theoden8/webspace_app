import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/reduced_motion.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';

import 'helpers/isolations.dart';

const _channel = MethodChannel('reduced_motion_test');

/// Pumps a reader of [ReducedMotion.of] under [motion]'s scope, with the
/// view's [MediaQuery] or [mediaQuery] in its place, and returns every
/// answer it built with.
Future<List<bool>> _pumpReader(
  WidgetTester tester, {
  required ReducedMotion motion,
  MediaQueryData? mediaQuery,
}) async {
  final seen = <bool>[];
  Widget reader = Builder(builder: (context) {
    seen.add(ReducedMotion.of(context));
    return const SizedBox.shrink();
  });
  if (mediaQuery != null) {
    reader = MediaQuery(data: mediaQuery, child: reader);
  }
  await tester.pumpWidget(ReducedMotionScope(motion: motion, child: reader));
  return seen;
}

void _answerMac(WidgetTester tester, {required bool on}) =>
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel,
        (call) async => call.method == 'reduceMotion' ? on : null);

Future<void> _macChanged(WidgetTester tester, {required bool on}) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('changed', on)),
      (_) {},
    );

SitePosture _posture() => WebViewModel(initUrl: 'https://example.org')
    .sitePosture(
        globalUserScripts: const <UserScriptConfig>[],
        isolation: fakeContainers());

bool? _linuxSetting() => WebViewFactory.siteSettings(
      (
        containerId: null,
        proxy: null,
        proxyUnavailable: false,
        proxyConfigured: false,
        relayDown: false,
        releasesContainerProxy: false,
      ),
      posture: _posture(),
      textZoom: 100,
      desktopMode: false,
    ).disableAnimations;

void main() {
  group('ReducedMotion answers each platform signal (A11Y-011)', () {
    testWidgets('no signal: motion runs (A11Y-011)', (tester) async {
      final motion = ReducedMotion(onMac: true, channel: _channel);
      _answerMac(tester, on: false);
      await motion.start();
      final seen = await _pumpReader(tester, motion: motion);
      expect(seen, [false]);
      expect(motion.reduced, isFalse);
    });

    testWidgets("Android's and Linux's disableAnimations (A11Y-011)",
        (tester) async {
      final motion = ReducedMotion(onMac: false);
      await motion.start();
      final seen = await _pumpReader(tester,
          motion: motion,
          mediaQuery: const MediaQueryData(disableAnimations: true));
      expect(seen, [true]);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      expect(motion.reduced, isTrue);
    });

    testWidgets("iOS's reduceMotion, which MediaQuery never carries, "
        'rebuilds its readers (A11Y-011)', (tester) async {
      final motion = ReducedMotion(onMac: false);
      await motion.start();
      final seen = await _pumpReader(tester, motion: motion);
      expect(seen, [false]);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pump();
      expect(seen.last, isTrue);
      expect(motion.reduced, isTrue);
    });

    testWidgets("the Mac's NSWorkspace answer, followed as it changes "
        '(A11Y-011)', (tester) async {
      final motion = ReducedMotion(onMac: true, channel: _channel);
      _answerMac(tester, on: true);
      await motion.start();
      final seen = await _pumpReader(tester, motion: motion);
      expect(seen, [true]);
      expect(motion.reduced, isTrue);

      await _macChanged(tester, on: false);
      await tester.pump();
      expect(seen.last, isFalse);
      expect(motion.reduced, isFalse);
    });
  });

  group('decorative motion stops under reduced motion (A11Y-011)', () {
    Future<void> pumpCorner(WidgetTester tester, {required bool still}) =>
        tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: still),
            child: TabBarCornerOverlay(
              corner: TabBarCorner.bottomRight,
              onTap: () {},
              onCornerChosen: (_) {},
            ),
          ),
        ));

    testWidgets("the corner button's press and glide are instant (A11Y-011)",
        (tester) async {
      await pumpCorner(tester, still: true);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
          Duration.zero);
      expect(tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).duration,
          Duration.zero);

      await pumpCorner(tester, still: false);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
          Motion.press);
      expect(tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).duration,
          Motion.settle);
    });
  });

  group("a Linux webview's pages hear it (A11Y-011)", () {
    testWidgets('siteSettings sends the answer as disableAnimations on Linux '
        '(A11Y-011)', (tester) async {
      await ReducedMotion.instance.start();
      expect(_linuxSetting(), isFalse);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      expect(_linuxSetting(), isTrue);
    }, skip: !hostIsLinux);
  });
}
