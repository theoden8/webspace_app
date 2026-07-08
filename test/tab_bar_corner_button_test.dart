import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';

void main() {
  late int taps;
  late List<Offset> begins;
  late List<Offset> updates;
  late int ends;
  late bool dragging;

  Widget harness() {
    taps = 0;
    begins = [];
    updates = [];
    ends = 0;
    dragging = false;
    return MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Stack(
            children: [
              Positioned(
                bottom: 16,
                right: 16,
                child: TabBarCornerButton(
                  dragging: dragging,
                  onTap: () => taps++,
                  onDragBegin: (pos) => setState(() {
                    dragging = true;
                    begins.add(pos);
                  }),
                  onDragUpdate: (pos) => updates.add(pos),
                  onDragEnd: () => setState(() {
                    dragging = false;
                    ends++;
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('tap reveals the strip without starting a drag',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TabBarCornerButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(begins, isEmpty);
    expect(updates, isEmpty);
  });

  testWidgets('long-press hold then move drags the button', (tester) async {
    await tester.pumpWidget(harness());
    final center = tester.getCenter(find.byType(TabBarCornerButton));
    final gesture = await tester.startGesture(center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(begins, hasLength(1), reason: 'long press should begin the drag');
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(updates, isNotEmpty);
    expect(updates.last.dx, closeTo(center.dx - 120, 1));
    await gesture.up();
    await tester.pump();
    expect(ends, greaterThanOrEqualTo(1));
    expect(taps, 0, reason: 'a completed drag must not count as a tap');
  });

  testWidgets('immediate press-and-drag (mouse style) also drags',
      (tester) async {
    await tester.pumpWidget(harness());
    final center = tester.getCenter(find.byType(TabBarCornerButton));
    final gesture = await tester.startGesture(center);
    // No hold: move straight away, past the touch slop, like dragging
    // with a mouse on an emulator.
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(begins, hasLength(1), reason: 'pan should begin the drag');
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(updates.last.dx, closeTo(center.dx - 120, 1));
    await gesture.up();
    await tester.pump();
    expect(ends, greaterThanOrEqualTo(1));
    expect(taps, 0);
  });

  testWidgets(
      'slight jitter during the long-press hold still begins the drag',
      (tester) async {
    await tester.pumpWidget(harness());
    final center = tester.getCenter(find.byType(TabBarCornerButton));
    final gesture = await tester.startGesture(center);
    // Under-slop wobble, as from an unsteady hand or mouse.
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(begins, hasLength(1));
    await gesture.up();
    await tester.pump();
  });
}
