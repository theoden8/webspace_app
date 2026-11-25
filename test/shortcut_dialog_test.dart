import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/shortcut_prompts.dart';

import 'helpers/localized.dart';

/// The iOS and macOS "Home Shortcut" dialogs (HS-010) as the overflow menu
/// shows them. The native side (ShortcutsUIButton's own page, NSWorkspace
/// opening `shortcuts://`) runs on a device only; here the iOS button is a
/// platform view whose `tapped` message is sent as the Runner sends it.
void main() {
  const viewType = 'org.codeberg.theoden8.webspace/shortcuts-link';

  /// Pumps a page whose button runs [open] with the page's prompts.
  Future<void> pumpOpener(
    WidgetTester tester, {
    required Future<void> Function(DialogShortcutPrompts prompts) open,
  }) async {
    await pumpLocalized(
      tester,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => open(DialogShortcutPrompts(context)),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The platform views the dialog asks the engine to create.
  List<Map<Object?, Object?>> fakeUiKitViews(WidgetTester tester) {
    final created = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        if (call.method == 'create') {
          created.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null));
    return created;
  }

  testWidgets('iOS explains the Shortcuts flow and embeds the native button '
      '(HS-010)', (tester) async {
    final created = fakeUiKitViews(tester);
    await pumpOpener(tester,
        open: (prompts) => prompts.explainIosShortcut('Wikipedia'));

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Add to Home Screen'), findsOneWidget);
    expect(find.textContaining('"Open Site" action under WebSpace, pick "Wikipedia"'),
        findsOneWidget);
    expect(find.byType(UiKitView), findsOneWidget);
    expect(created.single['viewType'], viewType);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    // No plain "Open Shortcuts" button: shortcuts:// cannot reach the app's page.
    expect(find.text('Open Shortcuts'), findsNothing);
  });

  testWidgets('a tap on the native Shortcuts button closes the dialog (HS-010)',
      (tester) async {
    final created = fakeUiKitViews(tester);
    await pumpOpener(tester,
        open: (prompts) => prompts.explainIosShortcut('Wikipedia'));
    final id = created.single['id']! as int;

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      '${viewType}_$id',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('tapped')),
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Cancel closes the iOS dialog and opens nothing (HS-010)',
      (tester) async {
    fakeUiKitViews(tester);
    final shortcutCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('org.codeberg.theoden8.webspace/shortcuts'),
      (call) async {
        shortcutCalls.add(call);
        return null;
      },
    );
    await pumpOpener(tester,
        open: (prompts) => prompts.explainIosShortcut('Wikipedia'));

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(shortcutCalls, isEmpty);
  });

  testWidgets('macOS asks with Open Shortcuts and Cancel (HS-010)',
      (tester) async {
    final answers = <bool>[];
    Future<void> ask(DialogShortcutPrompts prompts) async =>
        answers.add(await prompts.confirmMacosShortcut('Wikipedia'));

    await pumpOpener(tester, open: ask);
    expect(find.text('Add a Shortcut'), findsOneWidget);
    expect(find.textContaining('add it to the Dock or run it from the menu bar'),
        findsOneWidget);
    expect(find.byType(UiKitView), findsNothing);
    await tester.tap(find.text('Open Shortcuts'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(answers, [true, false]);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
