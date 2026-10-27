import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/route_cover.dart';

/// A page that counts its mounts, standing in for the platform view.
class _Page extends StatefulWidget {
  const _Page({required this.mounts});

  final List<int> mounts;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  void initState() {
    super.initState();
    widget.mounts.add(1);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// NAV-017: a macOS platform view takes every click Flutter has not painted
/// over, so the page is painted over while a route covers it. What the engine
/// does with the paint is the platform's; this holds what the app paints.
void main() {
  Finder veil() => find.descendant(
    of: find.byType(RouteCover),
    matching: find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color == RouteCover.veil,
    ),
  );

  testWidgets('NAV-017: a menu over the page veils it until it closes', (
    tester,
  ) async {
    final mounts = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              PopupMenuButton<int>(
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 1, child: Text('One')),
                ],
              ),
            ],
          ),
          body: RouteCover(page: _Page(mounts: mounts)),
        ),
      ),
    );
    expect(veil(), findsNothing, reason: 'the page on top takes its clicks');
    expect(RouteCover.veil.a, greaterThan(0), reason: 'a clear paint is none');

    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    expect(veil(), findsOneWidget);

    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.text('One'), findsNothing, reason: 'the click closed the menu');
    expect(veil(), findsNothing);
    expect(mounts, hasLength(1), reason: 'the platform view is never remounted');
  });

  testWidgets('NAV-017: a dialog over the page veils it too', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: RouteCover(
              page: Center(
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(veil(), findsOneWidget);
  });
}
