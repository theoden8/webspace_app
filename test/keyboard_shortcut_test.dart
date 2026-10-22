import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/back_gesture_controller.dart';
import 'package:webspace/controllers/keyboard_shortcut_controller.dart';
import 'package:webspace/controllers/site_reset_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/inappbrowser.dart' show InAppWebViewScreen;
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/shortcut_label.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/url_bar.dart';

import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';
import 'helpers/real_app.dart';

/// The page as the shortcuts see it: a site picked is recorded, not shown.
class _Page implements KeyboardShortcutHost {
  _Page({required this.kioskLocked});

  @override
  final bool kioskLocked;

  final opened = <WebViewModel>[];

  @override
  bool get mounted => true;

  @override
  bool get onTop => true;

  @override
  bool focusUrlBar() => true;

  @override
  bool findInPage() => true;

  @override
  Future<void> openSite(WebViewModel site) async => opened.add(site);
}

/// A controller the shortcut under test must not reach.
class _Untouched extends Fake
    implements TabsController, SiteResetController, BackGestureController {}

/// NAV-014: the desktop keyboard shortcuts. The keys are checked for both
/// platforms through [KeyboardShortcut.of]; the page's answers through the
/// shipped app, which `flutter test` runs as a Linux desktop, with the keys
/// sent as the embedder sends them.
void main() {
  /// What [key] asks for with [holding] down.
  Future<KeyboardShortcut?> press(
    LogicalKeyboardKey key, {
    required bool mac,
    List<LogicalKeyboardKey> holding = const [],
  }) async {
    for (final modifier in holding) {
      await simulateKeyDownEvent(modifier);
    }
    final shortcut = KeyboardShortcut.of(
      KeyDownEvent(
        // The keys are matched by their logical key.
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: key,
        timeStamp: Duration.zero,
      ),
      keyboard: HardwareKeyboard.instance,
      mac: mac,
    );
    for (final modifier in holding.reversed) {
      await simulateKeyUpEvent(modifier);
    }
    return shortcut;
  }

  const control = LogicalKeyboardKey.controlLeft;
  const command = LogicalKeyboardKey.metaLeft;
  const shift = LogicalKeyboardKey.shiftLeft;
  const alt = LogicalKeyboardKey.altLeft;

  // The shipped app answers the keys of the host the test runs on: Command
  // on a Mac, Control elsewhere.
  final primary = hostIsMacOS ? command : control;

  /// [key] pressed in the app with [holding] down, the host's command key
  /// unless named.
  Future<void> chord(
    WidgetTester tester, {
    required LogicalKeyboardKey key,
    List<LogicalKeyboardKey>? holding,
  }) async {
    final held = holding ?? [primary];
    for (final modifier in held) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final modifier in held.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await settleRealApp(tester);
  }

  Future<void> goBack(WidgetTester tester) => hostIsMacOS
      ? chord(tester, key: LogicalKeyboardKey.bracketLeft)
      : chord(tester, key: LogicalKeyboardKey.arrowLeft, holding: const [alt]);

  Future<void> goForward(WidgetTester tester) => hostIsMacOS
      ? chord(tester, key: LogicalKeyboardKey.bracketRight)
      : chord(tester, key: LogicalKeyboardKey.arrowRight, holding: const [alt]);

  Finder titled(String name) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(name));

  group('the keys (NAV-014)', () {
    for (final mac in [false, true]) {
      final primary = mac ? command : control;
      final on = mac ? 'on a Mac' : 'elsewhere';

      testWidgets('$on, the browser keys ask for the page\'s actions', (
        tester,
      ) async {
        Future<KeyboardShortcut?> chord(
          LogicalKeyboardKey key, {
          List<LogicalKeyboardKey> holding = const [],
        }) => press(key, mac: mac, holding: holding);

        expect(
          await chord(LogicalKeyboardKey.keyT, holding: [primary]),
          isA<OpenNewTab>(),
        );
        expect(
          await chord(LogicalKeyboardKey.keyW, holding: [primary]),
          isA<CloseActiveTab>(),
        );
        expect(
          await chord(LogicalKeyboardKey.keyL, holding: [primary]),
          isA<FocusUrlBar>(),
        );
        expect(
          await chord(LogicalKeyboardKey.keyR, holding: [primary]),
          isA<ReloadPage>(),
        );
        expect(await chord(LogicalKeyboardKey.f5), isA<ReloadPage>());
        expect(
          await chord(LogicalKeyboardKey.keyF, holding: [primary]),
          isA<FindInPage>(),
        );
        expect(
          await chord(LogicalKeyboardKey.tab, holding: [control]),
          isA<NextSite>(),
          reason: 'Control-Tab on every platform, a Mac\'s browsers too',
        );
        expect(
          await chord(LogicalKeyboardKey.tab, holding: [control, shift]),
          isA<PreviousSite>(),
        );
        expect(
          await chord(LogicalKeyboardKey.digit3, holding: [primary]),
          isA<SiteAt>().having((s) => s.place, 'place', 2),
        );
        expect(
          await chord(LogicalKeyboardKey.digit9, holding: [primary]),
          isA<LastSite>(),
        );
      });

      testWidgets('$on, the platform\'s back key goes back', (tester) async {
        final back = mac
            ? await press(
                LogicalKeyboardKey.bracketLeft,
                mac: mac,
                holding: [command],
              )
            : await press(
                LogicalKeyboardKey.arrowLeft,
                mac: mac,
                holding: [alt],
              );
        expect(back, isA<GoBack>());
        expect(
          await press(LogicalKeyboardKey.arrowLeft, mac: mac, holding: [alt]),
          mac ? isNull : isA<GoBack>(),
          reason: 'Option-Left moves the caret a word on a Mac',
        );
      });

      testWidgets('$on, the platform\'s forward key goes forward', (
        tester,
      ) async {
        final forward = mac
            ? await press(
                LogicalKeyboardKey.bracketRight,
                mac: mac,
                holding: [command],
              )
            : await press(
                LogicalKeyboardKey.arrowRight,
                mac: mac,
                holding: [alt],
              );
        expect(forward, isA<GoForward>());
        expect(
          await press(LogicalKeyboardKey.arrowRight, mac: mac, holding: [alt]),
          mac ? isNull : isA<GoForward>(),
        );
      });

      testWidgets('$on, select all and the other modifier are left alone', (
        tester,
      ) async {
        expect(
          await press(LogicalKeyboardKey.keyA, mac: mac, holding: [primary]),
          isNull,
          reason: 'the focused page or field selects all of its own',
        );
        expect(
          await press(
            LogicalKeyboardKey.keyT,
            mac: mac,
            holding: [mac ? control : command],
          ),
          isNull,
        );
        expect(
          await press(
            LogicalKeyboardKey.keyT,
            mac: mac,
            holding: [primary, shift],
          ),
          isNull,
        );
        expect(await press(LogicalKeyboardKey.keyT, mac: mac), isNull);
      });

      test('$on, no two shortcuts share a key', () {
        final keys = [
          for (final (key, _) in KeyboardShortcut.keys(mac: mac))
            (key.trigger, key.control, key.shift, key.alt, key.meta),
        ];
        expect(keys.toSet(), hasLength(keys.length));
      });
    }

    test('a held key asks once', () {
      final repeat = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.f5,
        logicalKey: LogicalKeyboardKey.f5,
        timeStamp: Duration.zero,
      );
      expect(
        KeyboardShortcut.of(
          repeat,
          keyboard: HardwareKeyboard.instance,
          mac: false,
        ),
        isNull,
      );
    });

    test('a locked kiosk keeps reload, back and forward only (KIOSK-002)', () {
      final kept = {
        for (final (_, shortcut) in KeyboardShortcut.keys(mac: false))
          if (shortcut.keptInKiosk) shortcut.runtimeType,
      };
      expect(kept, {ReloadPage, GoBack, GoForward});
    });
  });

  group('the gate (NAV-014)', () {
    final one = WebViewModel(initUrl: 'https://one.test', name: 'One');
    final two = WebViewModel(initUrl: 'https://two.test', name: 'Two');

    KeyboardShortcutController over(_Page page) {
      final sites = SiteRuntime()
        ..isolation = fakeSharedJar()
        ..applied(SitesLoaded([one, two]))
        ..selectedWebspaceId = WebspaceId.all;
      sites.seed(loaded: [one], shown: one);
      final untouched = _Untouched();
      return KeyboardShortcutController(
        sites,
        host: page,
        tabs: untouched,
        resets: untouched,
        back: untouched,
      );
    }

    test('a locked kiosk does not leave its site (KIOSK-002)', () {
      final page = _Page(kioskLocked: true);
      final keys = over(page);
      expect(keys.answerShortcut(const NextSite()), isFalse);
      expect(keys.answerShortcut(const SiteAt(1)), isFalse);
      expect(keys.answerShortcut(const FocusUrlBar()), isFalse);
      expect(page.opened, isEmpty);
    });

    test('unlocked, the same keys move along the sites', () {
      final page = _Page(kioskLocked: false);
      final keys = over(page);
      expect(keys.answerShortcut(const NextSite()), isTrue);
      expect(keys.answerShortcut(const SiteAt(1)), isTrue);
      expect(
        keys.answerShortcut(const SiteAt(0)),
        isTrue,
        reason: 'the site on screen: taken, nothing to open',
      );
      expect(
        keys.answerShortcut(const SiteAt(5)),
        isFalse,
        reason: 'no site there, so the key goes on to the page',
      );
      expect(page.opened, [two, two]);
    });
  });

  group('the page answers them (NAV-014)', () {
    Future<void> openOne(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
    }) async {
      await pumpRealApp(
        tester,
        prefs: prefs,
        sites: [
          WebViewModel(initUrl: 'https://one.test', name: 'One'),
          WebViewModel(initUrl: 'https://two.test', name: 'Two'),
          WebViewModel(initUrl: 'https://three.test', name: 'Three'),
        ],
      );
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'One');
      await attachWebViews(tester);
    }

    testWidgets('Ctrl/Cmd-T opens a tab and Ctrl/Cmd-W closes it', (
      tester,
    ) async {
      await openOne(tester);
      final one = appSite('One');
      final first = one.activeTabId;

      await chord(tester, key: LogicalKeyboardKey.keyT);
      expect(one.tabs, hasLength(2));
      expect(one.activeTabId, isNot(first));

      await chord(tester, key: LogicalKeyboardKey.keyW);
      expect(one.tabs, hasLength(1));
      expect(one.activeTabId, first);
    });

    testWidgets('Ctrl/Cmd-L puts the cursor in the URL bar, address selected', (
      tester,
    ) async {
      await openOne(tester, prefs: {'showUrlBar': true});

      await chord(tester, key: LogicalKeyboardKey.keyL);
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byType(UrlBar),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.focusNode.hasFocus, isTrue);
      expect(
        field.controller.selection,
        TextSelection(
          baseOffset: 0,
          extentOffset: field.controller.text.length,
        ),
      );
      expect(field.controller.text, appSite('One').currentUrl);
    });

    testWidgets('Ctrl/Cmd-R and F5 reload the page', (tester) async {
      await openOne(tester);

      webViewCalls.clear();
      await chord(tester, key: LogicalKeyboardKey.keyR);
      expect(webViewCalls, contains(#reload));

      webViewCalls.clear();
      await chord(tester, key: LogicalKeyboardKey.f5, holding: const []);
      expect(webViewCalls, contains(#reload));
    });

    testWidgets('Ctrl/Cmd-F opens and closes the find bar', (tester) async {
      await openOne(tester);

      await chord(tester, key: LogicalKeyboardKey.keyF);
      expect(find.byType(FindToolbar), findsOneWidget);
      await chord(tester, key: LogicalKeyboardKey.keyF);
      expect(find.byType(FindToolbar), findsNothing);
    });

    testWidgets('the back key goes back', (tester) async {
      await openOne(tester);

      webViewCalls.clear();
      await goBack(tester);
      expect(webViewCalls, contains(#canGoBack));
    });

    testWidgets('the forward key goes forward', (tester) async {
      await openOne(tester);

      webViewCalls.clear();
      await goForward(tester);
      expect(webViewCalls, contains(#canGoForward));
    });

    testWidgets('the digits and Ctrl-Tab move along the sites', (tester) async {
      await openOne(tester);

      await chord(tester, key: LogicalKeyboardKey.digit2);
      expect(titled('Two'), findsOneWidget);
      await chord(tester, key: LogicalKeyboardKey.digit9);
      expect(titled('Three'), findsOneWidget);
      await chord(
        tester,
        key: LogicalKeyboardKey.tab,
        holding: const [control],
      );
      expect(
        titled('One'),
        findsOneWidget,
        reason: 'round from the last to the first',
      );
      await chord(
        tester,
        key: LogicalKeyboardKey.tab,
        holding: const [control, shift],
      );
      expect(titled('Three'), findsOneWidget);
      if (!hostIsMacOS) {
        await chord(tester, key: LogicalKeyboardKey.pageUp);
        expect(titled('Two'), findsOneWidget);
      }
    });

    testWidgets('a menu over the page keeps the keys', (tester) async {
      await openOne(tester);
      await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>));
      await settleRealApp(tester);

      await chord(tester, key: LogicalKeyboardKey.keyT);
      expect(appSite('One').tabs, hasLength(1));
    });
  });

  group('a nested screen answers its own (NAV-014)', () {
    /// A site without tabs opens an address of another site in a nested
    /// screen over the page.
    Future<void> openNested(WidgetTester tester) async {
      final site = WebViewModel(initUrl: 'https://one.test', name: 'One')
        ..tabsEnabled = false
        ..externalLinkMode = ExternalLinkMode.inApp;
      await pumpRealApp(
        tester,
        sites: [
          site,
          WebViewModel(initUrl: 'https://two.test', name: 'Two'),
        ],
        prefs: {'showUrlBar': true},
      );
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'One');
      await attachWebViews(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'https://other.test/',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settleRealApp(tester);
      expect(find.byType(InAppWebViewScreen), findsOneWidget);
      await attachWebViews(tester);
    }

    Finder inNested(Finder finder) =>
        find.descendant(of: find.byType(InAppWebViewScreen), matching: finder);

    testWidgets('Ctrl/Cmd-R reloads the nested page, not the site behind it', (
      tester,
    ) async {
      await openNested(tester);

      webViewCalls.clear();
      await chord(tester, key: LogicalKeyboardKey.keyR);
      expect(webViewCalls.where((c) => c == #reload), hasLength(1));
    });

    testWidgets('Ctrl/Cmd-F and Ctrl/Cmd-L are the nested screen\'s', (
      tester,
    ) async {
      await openNested(tester);

      await chord(tester, key: LogicalKeyboardKey.keyF);
      expect(inNested(find.byType(FindToolbar)), findsOneWidget);
      await chord(tester, key: LogicalKeyboardKey.keyF);

      await chord(tester, key: LogicalKeyboardKey.keyL);
      final field = tester.widget<EditableText>(
        inNested(
          find.descendant(
            of: find.byType(UrlBar),
            matching: find.byType(EditableText),
          ),
        ),
      );
      expect(field.focusNode.hasFocus, isTrue);
      expect(field.controller.text, 'https://other.test/');
    });

    testWidgets(
      'the back key at the start of its history closes it, as back does',
      (tester) async {
        await openNested(tester);

        webViewCalls.clear();
        await goBack(tester);
        expect(webViewCalls, contains(#goBack));
        expect(find.byType(InAppWebViewScreen), findsNothing);
      },
    );

    testWidgets(
      'its menu leads with the site menu\'s row, less Home (NAV-015)',
      (tester) async {
        await openNested(tester);
        await tester.tap(inNested(find.byIcon(Icons.more_vert)));
        await settleRealApp(tester);

        final row = find
            .ancestor(of: find.byTooltip('Go Back'), matching: find.byType(Row))
            .first;
        for (final tooltip in ['Share', 'Refresh']) {
          expect(
            find.descendant(of: row, matching: find.byTooltip(tooltip)),
            findsOneWidget,
            reason: '$tooltip sits in the row beside Back',
          );
        }
        expect(find.byTooltip('Go to Home'), findsNothing);
        expect(find.text('Open in Browser'), findsOneWidget);
        webViewCalls.clear();
        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Refresh')),
        );
        await settleRealApp(tester);
        expect(webViewCalls.where((c) => c == #reload), hasLength(1));
      },
    );

    testWidgets('the forward key asks the nested page, and keeps the screen', (
      tester,
    ) async {
      await openNested(tester);

      webViewCalls.clear();
      await goForward(tester);
      expect(webViewCalls.where((c) => c == #canGoForward), hasLength(1));
      expect(find.byType(InAppWebViewScreen), findsOneWidget);
    });

    testWidgets('Ctrl/Cmd-W closes it; the page\'s keys stay the page\'s', (
      tester,
    ) async {
      await openNested(tester);

      await chord(tester, key: LogicalKeyboardKey.digit2);
      expect(
        find.byType(InAppWebViewScreen),
        findsOneWidget,
        reason: 'site switching is not the nested screen\'s',
      );

      await chord(tester, key: LogicalKeyboardKey.keyW);
      expect(find.byType(InAppWebViewScreen), findsNothing);
      expect(titled('One'), findsOneWidget);
      expect(titled('Two'), findsNothing);
    });
  });

  group('the menus name the keys (NAV-014)', () {
    const names = DefaultMaterialLocalizations();
    String label<T extends KeyboardShortcut>({required bool mac}) =>
        describeKey(
          KeyboardShortcut.keyFor<T>(mac: mac)!,
          names: names,
          mac: mac,
        );

    test('as the platform\'s menus write them', () {
      expect(label<OpenNewTab>(mac: false), 'Ctrl+T');
      expect(label<OpenNewTab>(mac: true), '⌘T');
      expect(label<GoBack>(mac: false), 'Alt+←');
      expect(label<GoBack>(mac: true), '⌘[');
      expect(label<PreviousSite>(mac: false), 'Ctrl+Shift+Tab');
      expect(label<PreviousSite>(mac: true), '⌃⇧⇥');
      expect(
        label<ReloadPage>(mac: false),
        'Ctrl+R',
        reason: 'the first of its keys, before F5',
      );
    });

    testWidgets('the site menu shows New tab and Find in page with theirs', (
      tester,
    ) async {
      await pumpRealApp(
        tester,
        sites: [WebViewModel(initUrl: 'https://one.test', name: 'One')],
      );
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'One');
      await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>));
      await settleRealApp(tester);

      Finder keysOf(String item) => find.descendant(
        of: find.ancestor(of: find.text(item), matching: find.byType(Row)),
        matching: find.byType(ShortcutKeys),
      );
      expect(
        tester.widget<ShortcutKeys>(keysOf('New tab')).keys,
        hostIsMacOS ? '⌘T' : 'Ctrl+T',
      );
      expect(
        tester.widget<ShortcutKeys>(keysOf('Find')).keys,
        hostIsMacOS ? '⌘F' : 'Ctrl+F',
      );
      expect(keysOf('Settings'), findsNothing);
    });
  });
}
