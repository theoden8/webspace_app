import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/widgets/theme_mode_icon.dart';

void main() {
  group('Theme Mode Tests', () {
    test('ThemeMode to WebViewTheme conversion', () {
      expect(ThemeMode.light.webViewTheme, WebViewTheme.light);
      expect(ThemeMode.dark.webViewTheme, WebViewTheme.dark);
      expect(ThemeMode.system.webViewTheme, WebViewTheme.system);
    });

    test('ThemeMode serialization for SharedPreferences', () {
      // Test that we can save/restore theme modes using their index
      // Flutter's ThemeMode enum order: system, light, dark
      expect(ThemeMode.system.index, 0);
      expect(ThemeMode.light.index, 1);
      expect(ThemeMode.dark.index, 2);

      // Test restoration
      expect(ThemeMode.values[0], ThemeMode.system);
      expect(ThemeMode.values[1], ThemeMode.light);
      expect(ThemeMode.values[2], ThemeMode.dark);
    });

    test('Theme icon mapping', () {
      expect(themeModeIcon(ThemeMode.light), Icons.wb_sunny);
      expect(themeModeIcon(ThemeMode.dark), Icons.nights_stay);
      expect(themeModeIcon(ThemeMode.system), Icons.brightness_auto);
    });

    test('WebViewTheme names are what the shim reads and site JSON stores',
        () {
      expect(WebViewTheme.values.map((t) => t.name),
          ['light', 'dark', 'system']);
    });
  });

  group('Theme Integration Tests', () {
    testWidgets('MaterialApp respects themeMode', (WidgetTester tester) async {
      ThemeMode currentMode = ThemeMode.light;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            return MaterialApp(
              themeMode: currentMode,
              theme: ThemeData.light(),
              darkTheme: ThemeData.dark(),
              home: Scaffold(
                appBar: AppBar(
                  title: Text('Theme Test'),
                  actions: [
                    IconButton(
                      icon: Icon(Icons.brightness_6),
                      onPressed: () {
                        setState(() {
                          currentMode = currentMode == ThemeMode.light
                              ? ThemeMode.dark
                              : ThemeMode.light;
                        });
                      },
                    ),
                  ],
                ),
                body: Center(
                  child: Text('Current theme: $currentMode'),
                ),
              ),
            );
          },
        ),
      );

      // Verify initial light mode
      expect(currentMode, ThemeMode.light);
      expect(find.text('Current theme: ThemeMode.light'), findsOneWidget);

      // Tap theme toggle button
      await tester.tap(find.byIcon(Icons.brightness_6));
      await tester.pumpAndSettle();

      // Verify dark mode
      expect(currentMode, ThemeMode.dark);
      expect(find.text('Current theme: ThemeMode.dark'), findsOneWidget);
    });
  });

  group('Color Scheme Tests', () {
    test('CSS color-scheme meta tag detection', () {
      // These are the patterns we look for in HTML
      final patterns = [
        'name="color-scheme"',
        'content="light dark"',
        'prefers-color-scheme',
      ];

      // Test HTML with theme support
      final withTheme = '''
        <meta name="color-scheme" content="light dark">
        <style>
          @media (prefers-color-scheme: dark) {
            body { background: black; }
          }
        </style>
      ''';

      for (final pattern in patterns) {
        expect(withTheme.contains(pattern), true,
            reason: 'Should contain $pattern');
      }

      // Test HTML without theme support
      final withoutTheme = '''
        <style>
          body { background: white; }
        </style>
      ''';

      expect(withoutTheme.contains('color-scheme'), false);
      expect(withoutTheme.contains('prefers-color-scheme'), false);
    });
  });
}
