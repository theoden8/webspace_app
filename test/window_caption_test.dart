import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/window_caption.dart';
import 'package:webspace/widgets/caption_tint.dart';

/// NAV-019: Android draws the header of a desktop window over the app, its
/// buttons light or dark as the app tells it. The transparent header itself
/// and the padding Flutter gives it are the platform's, which no test here
/// reaches.
void main() {
  const channel = MethodChannel('test/window_caption');
  late List<Object?> told;

  setUp(() {
    told = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setLight') told.add(call.arguments);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget app(ThemeMode mode, {required WindowCaption caption}) => MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode: mode,
        builder: (context, child) => CaptionTint(
          caption: caption,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(),
      );

  testWidgets('NAV-019 the header follows the app\'s brightness, told once '
      'per change', (tester) async {
    final caption = WindowCaption(drawn: true, channel: channel);

    await tester.pumpWidget(app(ThemeMode.light, caption: caption));
    await tester.pumpAndSettle();
    expect(told, [true], reason: 'dark buttons over a light app bar');

    await tester.pumpWidget(app(ThemeMode.dark, caption: caption));
    await tester.pumpAndSettle();
    expect(told, [true, false]);

    await tester.pumpWidget(app(ThemeMode.dark, caption: caption));
    await tester.pumpAndSettle();
    expect(told, [true, false], reason: 'a rebuild changes nothing');
  });

  testWidgets('NAV-019 a platform that draws no header is told nothing',
      (tester) async {
    final caption = WindowCaption(drawn: false, channel: channel);
    await tester.pumpWidget(app(ThemeMode.light, caption: caption));
    await tester.pumpAndSettle();
    expect(told, isEmpty);
  });
}
