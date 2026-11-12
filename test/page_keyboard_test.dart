import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/page_keyboard.dart';
import 'package:webspace/services/keyboard_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_webview_controller.dart';

final _a = SiteId('site-a');
final _b = SiteId('site-b');
final _tab = TabId('t1');

/// The page as `WebSpacePage` wires its keyboard: followed from build,
/// watching its route, covered by its drawer; a field of its own stands in
/// for the URL bar or a field in the site's page.
class _Page extends StatefulWidget {
  const _Page({required this.keyboard, required this.face});

  final PageKeyboard keyboard;
  final ValueNotifier<PageFace> face;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) widget.keyboard.watch(route, scope: FocusScope.of(context));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.face,
        builder: (context, _) {
          widget.keyboard.follow(widget.face.value);
          return Scaffold(
            appBar: AppBar(),
            drawer: const Drawer(),
            onDrawerChanged: (open) {
              if (open) widget.keyboard.covered();
            },
            body: const TextField(key: Key('page-field')),
          );
        },
      );
}

class _Rig {
  final page = FakeWebViewController();
  final face = ValueNotifier<PageFace>((site: _a, tab: _tab));
  late final PageKeyboard keyboard = PageKeyboard(
      pageOf: (site) => site == _a ? page : null);
  final navigator = GlobalKey<NavigatorState>();

  Future<void> pump(WidgetTester tester) async {
    addTearDown(keyboard.dispose);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [coverRouteObserver],
      home: _Page(keyboard: keyboard, face: face),
    ));
    await tester.tap(find.byKey(const Key('page-field')));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
  }

  bool get blurred => page.evaluated.any((s) => s.contains('.blur()'));

  Future<void> push(WidgetTester tester, {required bool field}) async {
    final pushed = navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: field
            ? const TextField(key: Key('screen-field'), autofocus: true)
            : const Text('settings'),
      ),
    ));
    expect(pushed, isNotNull);
    await tester.pumpAndSettle();
  }
}

void main() {
  group('NAV-021 the keyboard leaves with the page that raised it', () {
    testWidgets('another site on screen hides it', (tester) async {
      final rig = _Rig();
      await rig.pump(tester);

      rig.face.value = (site: _b, tab: _tab);
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('a rebuild that shows the same page leaves it up',
        (tester) async {
      final rig = _Rig();
      await rig.pump(tester);

      tester.element(find.byType(_Page)).markNeedsBuild();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('the drawer blurs the page under it and hides it',
        (tester) async {
      final rig = _Rig();
      await rig.pump(tester);

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      expect(rig.blurred, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('a screen pushed over the page blurs the page and hides it',
        (tester) async {
      final rig = _Rig();
      await rig.pump(tester);

      await rig.push(tester, field: false);

      expect(rig.blurred, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('a screen that focuses a field of its own keeps its keyboard',
        (tester) async {
      final rig = _Rig();
      await rig.pump(tester);

      await rig.push(tester, field: true);

      final field = tester.widget<EditableText>(find.descendant(
          of: find.byKey(const Key('screen-field')),
          matching: find.byType(EditableText)));
      expect(field.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('a switch behind a screen with a focused field leaves it up',
        (tester) async {
      final rig = _Rig();
      await rig.pump(tester);
      await rig.push(tester, field: true);

      rig.face.value = (site: _b, tab: _tab);
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);
    });
  });
}
