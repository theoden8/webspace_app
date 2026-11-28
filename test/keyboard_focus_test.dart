import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'package:webspace/widgets/url_bar.dart';

import 'helpers/real_app.dart';

/// What a key press puts focus on, as a screen reader names it: the focused
/// semantics node's tooltip, else its label's first line; `page` for a site's
/// webview.
String focusedName() {
  final node = FocusManager.instance.primaryFocus;
  if (node?.context?.findAncestorWidgetOfExactType<inapp.InAppWebView>() !=
      null) {
    return 'page';
  }
  final data = find.semantics
      .byPredicate((node) =>
          node.getSemanticsData().flagsCollection.isFocused == Tristate.isTrue)
      .evaluate()
      .lastOrNull
      ?.getSemanticsData();
  if (data == null) return 'nothing';
  return data.tooltip.isNotEmpty ? data.tooltip : data.label.split('\n').first;
}

/// The page's own focus, as Linux's webview takes it: every key it is given,
/// Tab included, so only a key taken before it gets out.
void keepEveryKey(FocusNode page) {
  page.onKeyEvent = (_, _) => KeyEventResult.handled;
}

Future<void> tab(WidgetTester tester, {bool back = false}) async {
  if (back) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (back) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Tab, or Shift-Tab with [back], until [name] has focus.
Future<void> tabTo(
  WidgetTester tester, {
  required String name,
  bool back = false,
}) async {
  for (var i = 0; i < 30 && focusedName() != name; i++) {
    await tab(tester, back: back);
  }
  expect(focusedName(), name, reason: 'Tab reaches $name');
}

/// The controls Tab (Shift-Tab with [back]) visits from [from] until it is
/// back at [from], each press moving focus on.
Future<List<String>> roundFrom(
  WidgetTester tester, {
  required String from,
  bool back = false,
}) async {
  await tabTo(tester, name: from);
  final visited = [from];
  for (var i = 0; i < 40; i++) {
    final before = FocusManager.instance.primaryFocus;
    await tab(tester, back: back);
    expect(FocusManager.instance.primaryFocus, isNot(same(before)),
        reason: 'stuck on ${visited.last}');
    final name = focusedName();
    if (name == from) return visited;
    visited.add(name);
  }
  fail('Tab never came back to $from: $visited');
}

/// [key] with the platform's command key held: Command on a Mac.
Future<void> command(
  WidgetTester tester, {
  required LogicalKeyboardKey key,
}) async {
  final held = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(held);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(held);
  await settleRealApp(tester);
}

Future<void> press(
  WidgetTester tester, {
  required LogicalKeyboardKey key,
}) async {
  await tester.sendKeyEvent(key);
  await settleRealApp(tester);
}

const _torChannels = [
  'org.codeberg.theoden8.webspace/tor/events',
  'org.codeberg.theoden8.webspace/tor/logs',
];

final _desktops = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.linux,
});

/// The keyboard on a desktop, in the shipped app: Tab and Shift-Tab go round
/// each screen's controls in order (NAV-022), Escape closes what is over the
/// page, and the page's shortcuts answer with the platform's command key and
/// take the keys back from a webview that keeps every key (NAV-014).
void main() {
  late SemanticsHandle semantics;
  setUp(() => semantics = SemanticsBinding.instance.ensureSemantics());
  tearDown(() => semantics.dispose());

  Future<void> openApp(
    WidgetTester tester, {
    required List<WebViewModel> sites,
    Map<String, Object> prefs = const {},
  }) async {
    // A Mac starts its built-in Tor's listeners, whose channels no test
    // platform answers.
    for (final channel in _torChannels) {
      tester.binding.defaultBinaryMessenger.setMockStreamHandler(
        EventChannel(channel),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
    }
    await pumpRealApp(tester, sites: sites, prefs: prefs);
  }

  Future<void> openOne(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    await openApp(
      tester,
      prefs: prefs,
      sites: [
        WebViewModel(initUrl: 'https://one.test', name: 'One'),
        WebViewModel(initUrl: 'https://two.test', name: 'Two'),
      ],
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
  }

  Finder titled(String name) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(name));

  group('Tab and Shift-Tab (NAV-022)', () {
    testWidgets('go round the site page, the app bar first, then the page', (
      tester,
    ) async {
      await openOne(tester);

      final forward = await roundFrom(tester, from: 'Open navigation menu');
      expect(forward.take(4), ['Open navigation menu', 'Tabs', 'Show menu', 'page']);
      expect(forward.toSet(), hasLength(forward.length));
      final backward = await roundFrom(tester, from: 'Open navigation menu', back: true);
      expect(backward, [forward.first, ...forward.skip(1).toList().reversed]);
    }, variant: _desktops);

    testWidgets('go round App Settings and reach its back button again', (
      tester,
    ) async {
      await openApp(tester, sites: [
        WebViewModel(initUrl: 'https://one.test', name: 'One'),
      ]);
      await tester.tap(find.byTooltip('App Settings'));
      await settleRealApp(tester);

      // The list is longer than the window, so a row scrolled under the app
      // bar sits above its back button.
      final forward = await roundFrom(tester, from: 'Back');
      expect(forward.take(3), ['Back', 'Appearance', 'Behaviour']);
      expect(forward, containsAllInOrder(['Network', 'Privacy', 'Version']));
      final backward = await roundFrom(tester, from: 'Back', back: true);
      expect(backward, [forward.first, ...forward.skip(1).toList().reversed]);
    }, variant: _desktops);

    testWidgets('stay in the open drawer, which Escape closes', (tester) async {
      await openOne(tester);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await settleRealApp(tester);

      final round = await roundFrom(tester, from: 'Add Site');
      expect(round, containsAll(['Add Site', 'One', 'Two']));
      expect(round, isNot(contains('page')));
      await press(tester, key: LogicalKeyboardKey.escape);
      expect(
        tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
        isFalse,
      );
    }, variant: _desktops);

    testWidgets('pass over a hidden tab\'s page', (tester) async {
      await openOne(tester);
      await command(tester, key: LogicalKeyboardKey.keyT);
      await attachWebViews(tester);
      expect(appSite('One').tabs, hasLength(2));

      final round = await roundFrom(tester, from: 'Open navigation menu');
      expect(round.where((name) => name == 'page'), hasLength(1));
      for (var i = 0; i < round.length; i++) {
        await tab(tester);
        final page = FocusManager.instance.primaryFocus?.context;
        if (focusedName() == 'page') {
          expect(page?.findAncestorWidgetOfExactType<Offstage>()?.offstage,
              isNot(isTrue), reason: 'the page on screen, not the warm one');
        }
      }
    }, variant: _desktops);
  });

  group('Escape closes what is over the page (NAV-022)', () {
    testWidgets('the site menu', (tester) async {
      await openOne(tester);
      await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>));
      await settleRealApp(tester);
      expect(find.byType(PopupMenuItem<SiteMenuAction>), findsWidgets);

      await press(tester, key: LogicalKeyboardKey.escape);
      expect(find.byType(PopupMenuItem<SiteMenuAction>), findsNothing);
      expect(titled('One'), findsOneWidget);
    }, variant: _desktops);

    testWidgets('the Tabs sheet', (tester) async {
      await openOne(tester);
      await openTabsSheet(tester);
      expect(find.byType(TabsSheet), findsOneWidget);

      await press(tester, key: LogicalKeyboardKey.escape);
      expect(find.byType(TabsSheet), findsNothing);
    }, variant: _desktops);

    testWidgets('a hint', (tester) async {
      await openApp(tester, sites: [
        WebViewModel(initUrl: 'https://one.test', name: 'One'),
      ]);
      await tester.tap(find.byTooltip('App Settings'));
      await settleRealApp(tester);
      await tester.tap(find.text('Appearance'));
      await settleRealApp(tester);
      await tester.tap(find.byType(HintButton).first);
      await settleRealApp(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      await press(tester, key: LogicalKeyboardKey.escape);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(HintButton), findsWidgets);
    }, variant: _desktops);

    testWidgets('the prompt over unsaved site settings, which keeps editing', (
      tester,
    ) async {
      await openOne(tester);
      await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>));
      await settleRealApp(tester);
      await tester.tap(find.text('Settings').last);
      await settleRealApp(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      final agent = find.byType(TextFormField).first;
      await tester.enterText(agent, 'Agent/1.0');
      await settleRealApp(tester);

      await tabTo(tester, name: 'Back');
      await press(tester, key: LogicalKeyboardKey.enter);
      expect(find.text('Discard changes?'), findsOneWidget);
      await press(tester, key: LogicalKeyboardKey.escape);
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.pageBack();
      await settleRealApp(tester);
      expect(find.text('Discard changes?'), findsOneWidget,
          reason: 'the edit is still there to discard');
    }, variant: _desktops);
  });

  group('the page\'s shortcuts (NAV-014)', () {
    testWidgets('switch sites, reload, find and focus the URL bar', (
      tester,
    ) async {
      await openOne(tester, prefs: {'showUrlBar': true});

      await command(tester, key: LogicalKeyboardKey.digit2);
      expect(titled('Two'), findsOneWidget);
      await attachWebViews(tester);

      webViewCalls.clear();
      await command(tester, key: LogicalKeyboardKey.keyR);
      expect(webViewCalls, contains(#reload));

      await command(tester, key: LogicalKeyboardKey.keyF);
      expect(find.byType(FindToolbar), findsOneWidget);
      await press(tester, key: LogicalKeyboardKey.escape);
      expect(find.byType(FindToolbar), findsNothing);

      await command(tester, key: LogicalKeyboardKey.keyL);
      final field = tester.widget<EditableText>(find.descendant(
        of: find.byType(UrlBar),
        matching: find.byType(EditableText),
      ));
      expect(field.focusNode.hasFocus, isTrue);
    }, variant: _desktops);

    testWidgets('F6 takes the keys from a page that keeps every key', (
      tester,
    ) async {
      await openOne(tester);
      await tabTo(tester, name: 'page');
      final page = FocusManager.instance.primaryFocus!;
      keepEveryKey(page);

      await tab(tester);
      expect(focusedName(), 'page', reason: 'the page keeps Tab');
      await press(tester, key: LogicalKeyboardKey.f6);
      expect(focusedName(), 'Open navigation menu');
      await tab(tester);
      expect(focusedName(), 'Tabs');
    }, variant: _desktops);

    testWidgets('F6 puts the cursor in the URL bar where it is on', (
      tester,
    ) async {
      await openOne(tester, prefs: {'showUrlBar': true});
      await tabTo(tester, name: 'page');
      keepEveryKey(FocusManager.instance.primaryFocus!);

      await press(tester, key: LogicalKeyboardKey.f6);
      final field = tester.widget<EditableText>(find.descendant(
        of: find.byType(UrlBar),
        matching: find.byType(EditableText),
      ));
      expect(field.focusNode.hasFocus, isTrue);
    }, variant: _desktops);
  });
}
