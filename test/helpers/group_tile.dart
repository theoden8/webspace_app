import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';

Color groupBackground(WidgetTester tester, {required WebspaceId id}) {
  final tile = find.byWidgetPredicate(
    (widget) => widget is WebspaceGroupTile && widget.webspace.id == id,
  );
  return tester
      .widgetList<DecoratedBox>(
        find.descendant(of: tile, matching: find.byType(DecoratedBox)),
      )
      .map((box) => box.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((decoration) => decoration.color != null)
      .color!;
}
