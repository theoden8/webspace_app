import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/services/shortcut_menu.dart';

/// A screen that takes the keys, recording what it is asked to run.
class _Screen implements ShortcutScreen {
  _Screen({required this.onTop});

  @override
  bool onTop;

  final ran = <KeyboardShortcut>[];

  @override
  bool answerShortcut(KeyboardShortcut shortcut) {
    ran.add(shortcut);
    return true;
  }
}

const _channel = MethodChannel('org.codeberg.theoden8.webspace/shortcut_menu');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppLocalizations en;
  late List<MethodCall> calls;

  setUpAll(() async => en = await AppLocalizations.delegate.load(
        const Locale('en'),
      ));

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  List<Map<Object?, Object?>> itemsOf(MethodCall call) => [
        for (final item in (call.arguments as Map)['items'] as List)
          item as Map<Object?, Object?>,
      ];

  Future<void> press(int id) async {
    await messenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall('pressed', {'id': id})),
      (_) {},
    );
  }

  group('Site menu in the macOS menu bar', () {
    test('lists every shortcut the Mac keys bind, once, at its first key', () {
      ShortcutMenu(offered: true)
          .show(ShortcutMenu.contentOf(en, kioskLocked: false));

      final bound = <KeyboardShortcut, SingleActivator>{};
      for (final (key, shortcut)
          in KeyboardShortcut.keys(on: KeyConvention.mac)) {
        bound.putIfAbsent(shortcut, () => key);
      }
      expect(calls.single.method, 'show');
      expect((calls.single.arguments as Map)['title'], 'Site');
      final items = itemsOf(calls.single);
      expect(items, hasLength(bound.length));
      for (final (id, MapEntry(key: shortcut, value: key))
          in bound.entries.indexed) {
        expect(items[id], {
          'id': id,
          'title': shortcut.menuTitle(en),
          'key': ShortcutMenu.keyEquivalent(key.trigger),
          'command': key.meta,
          'shift': key.shift,
          'option': key.alt,
          'control': key.control,
        }, reason: '$shortcut');
        expect(items[id]['key'], isNot(isEmpty), reason: '$shortcut');
      }
    });

    test('writes each key as an NSMenuItem takes it', () {
      ShortcutMenu(offered: true)
          .show(ShortcutMenu.contentOf(en, kioskLocked: false));
      final byTitle = {
        for (final item in itemsOf(calls.single))
          item['title']: (
            item['key'],
            [
              for (final modifier in ['control', 'option', 'shift', 'command'])
                if (item[modifier] == true) modifier,
            ].join('+'),
          ),
      };
      expect(byTitle, {
        'New Tab': ('t', 'command'),
        'Reopen Closed Tab': ('t', 'shift+command'),
        'Close Tab': ('w', 'command'),
        'Edit Address': ('l', 'command'),
        'Reload Page': ('r', 'command'),
        'Find in Page': ('f', 'command'),
        'Back': ('[', 'command'),
        'Forward': (']', 'command'),
        'Next Site': ('\t', 'control'),
        'Previous Site': ('\t', 'control+shift'),
        for (var n = 1; n <= 8; n++) 'Site $n': ('$n', 'command'),
        'Last Site': ('9', 'command'),
        'Move Focus Out of Page': ('\u{F709}', ''),
        'Show or Hide Sidebar': ('z', 'option+command'),
      });
    });

    test('a locked kiosk lists only reload, back and forward', () {
      ShortcutMenu(offered: true)
          .show(ShortcutMenu.contentOf(en, kioskLocked: true));
      expect([for (final item in itemsOf(calls.single)) item['title']],
          ['Reload Page', 'Back', 'Forward']);
    });

    test('sends a menu once, and again in another language', () async {
      final menu = ShortcutMenu(offered: true);
      menu.show(ShortcutMenu.contentOf(en, kioskLocked: false));
      menu.show(ShortcutMenu.contentOf(en, kioskLocked: false));
      expect(calls, hasLength(1));

      final de = await AppLocalizations.delegate.load(const Locale('de'));
      menu.show(ShortcutMenu.contentOf(de, kioskLocked: false));
      expect(calls, hasLength(2));
      expect((calls.last.arguments as Map)['title'], de.shortcutMenuTitle);
    });

    test('sends nothing off macOS', () {
      ShortcutMenu(offered: false)
          .show(ShortcutMenu.contentOf(en, kioskLocked: false));
      expect(calls, isEmpty);
    });

    test('a press runs its shortcut on the screen on top, once', () async {
      final page = _Screen(onTop: false);
      final nested = _Screen(onTop: true);
      final pageKeys = KeyboardShortcuts(page)..start();
      final nestedKeys = KeyboardShortcuts(nested)..start();
      addTearDown(pageKeys.dispose);
      addTearDown(nestedKeys.dispose);

      final content = ShortcutMenu.contentOf(en, kioskLocked: false);
      ShortcutMenu(offered: true).show(content);
      final find =
          content.lines.indexWhere((line) => line.shortcut is FindInPage);
      final third =
          content.lines.indexWhere((line) => line.shortcut == const SiteAt(2));

      await press(find);
      expect(nested.ran, [const FindInPage()]);
      expect(page.ran, isEmpty);

      nested.onTop = false;
      page.onTop = true;
      await press(third);
      expect(page.ran, [const SiteAt(2)]);
      expect(nested.ran, [const FindInPage()]);

      await press(content.lines.length);
      page.onTop = false;
      await press(find);
      expect(page.ran, [const SiteAt(2)]);
      expect(nested.ran, [const FindInPage()]);
    });
  });
}
