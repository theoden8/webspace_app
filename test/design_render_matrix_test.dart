// Do the token values still lay out?
//
// design_tokens_validity_test.dart checks the numbers against each other. It
// cannot see that Spacing.xl = 48 overflows the URL bar on a 320pt phone at
// 200% text, because that only exists once the widgets are laid out. So every
// widget that reads the tokens is rendered across the matrix that actually
// varies: narrow and wide, both brightnesses, and text scaled to the OS
// maximum.
//
// A RenderFlex overflow fails a widget test by itself, which is what makes
// this cheap: the assertion is "it rendered", and Flutter supplies the rest.
// Tap targets are checked explicitly because a control shrinking under a
// smaller token overflows nothing and simply stops being hittable.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/widgets/url_bar.dart';

/// Narrow is a small phone in portrait; wide is a tablet pane. Both are real
/// places this chrome renders.
const List<double> _widths = [320, 411, 800];

/// 1.0 is the default, 1.3 the common "larger text" setting, 2.0 the ceiling
/// Android and iOS both allow.
const List<double> _textScales = [1.0, 1.3, 2.0];

final Map<String, Widget Function()> _subjects = {
  'url-bar (https)': () =>
      const UrlBar(currentUrl: 'https://codeberg.org/theoden8/webspace', onUrlSubmitted: _ignore),
  'url-bar (http)': () =>
      const UrlBar(currentUrl: 'http://example.org', onUrlSubmitted: _ignore),
  'url-bar (long url)': () => const UrlBar(
      currentUrl:
          'https://example.org/a/very/long/path/that/keeps/going/and/going?query=1&more=2',
      onUrlSubmitted: _ignore),
  'hint-button': () => const HintButton(
      title: 'Cookie isolation',
      description:
          'Each site keeps its own cookie jar, so a login on one site is invisible to the others.'),
  'tab-corner-button': () => TabBarCornerButton(
        dragging: false,
        onTap: () {},
        onDragBegin: (_) {},
        onDragUpdate: (_) {},
        onDragEnd: () {},
      ),
  'tab-corner-button (dragging)': () => TabBarCornerButton(
        dragging: true,
        onTap: () {},
        onDragBegin: (_) {},
        onDragUpdate: (_) {},
        onDragEnd: () {},
      ),
};

void _ignore(String _) {}

Widget _host({
  required Widget child,
  required Brightness brightness,
  required double width,
  required double textScale,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(colorScheme: buildAccentColorScheme(accentBlue, brightness)),
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

void main() {
  for (final subject in _subjects.entries) {
    for (final width in _widths) {
      for (final scale in _textScales) {
        for (final brightness in Brightness.values) {
          testWidgets(
            '${subject.key} lays out at ${width.toInt()}pt, '
            '${scale}x text, ${brightness.name}',
            (tester) async {
              tester.view.physicalSize = Size(width, 800);
              tester.view.devicePixelRatio = 1.0;
              addTearDown(tester.view.reset);

              await tester.pumpWidget(_host(
                child: subject.value(),
                brightness: brightness,
                width: width,
                textScale: scale,
              ));
              await tester.pump();

              // pumpWidget rethrows a layout overflow, so reaching here means
              // it fit. Assert something real about the result as well, so the
              // test cannot pass on a widget that rendered nothing.
              expect(tester.takeException(), isNull);
              expect(find.byType(subject.value().runtimeType), findsOneWidget);
            },
          );
        }
      }
    }
  }

  testWidgets('the URL bar submit button stays hittable once editing', (tester) async {
    await tester.pumpWidget(_host(
      child: const UrlBar(currentUrl: 'https://example.org', onUrlSubmitted: _ignore),
      brightness: Brightness.light,
      width: 320,
      textScale: 1.0,
    ));
    // The submit button only exists in edit mode, which is also the state
    // where the bar is most crowded.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final button = find.byType(IconButton);
    expect(button, findsOneWidget);
    final size = tester.getSize(button);
    expect(size.shortestSide, greaterThanOrEqualTo(TapTargets.compact),
        reason: 'IconSizes.action + Spacing.xs padding no longer reaches the '
            'compact tap-target floor (${size.shortestSide})');
  });

  testWidgets('the corner button is a tap target, not just an icon', (tester) async {
    await tester.pumpWidget(_host(
      child: TabBarCornerButton(
        dragging: false,
        onTap: () {},
        onDragBegin: (_) {},
        onDragUpdate: (_) {},
        onDragEnd: () {},
      ),
      brightness: Brightness.light,
      width: 320,
      textScale: 1.0,
    ));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(TabBarCornerButton));
    expect(size.shortestSide, greaterThanOrEqualTo(TapTargets.compact),
        reason: 'IconSizes.floating + 2 * FloatingButton.padding is below the '
            'tap-target floor (${size.shortestSide})');
  });

  testWidgets('the corner button grows while dragged', (tester) async {
    // AnimatedScale is a paint transform, so the laid-out box does not change
    // and reading the size would prove nothing. The scale itself is the token
    // reaching the screen.
    double scaleWhen(bool dragging) {
      return tester
          .widget<AnimatedScale>(find.byType(AnimatedScale))
          .scale;
    }

    for (final dragging in [false, true]) {
      await tester.pumpWidget(_host(
        child: TabBarCornerButton(
          dragging: dragging,
          onTap: () {},
          onDragBegin: (_) {},
          onDragUpdate: (_) {},
          onDragEnd: () {},
        ),
        brightness: Brightness.light,
        width: 320,
        textScale: 1.0,
      ));
      await tester.pumpAndSettle();
      expect(scaleWhen(dragging), dragging ? FloatingButton.dragScale : 1.0);
    }
  });
}
