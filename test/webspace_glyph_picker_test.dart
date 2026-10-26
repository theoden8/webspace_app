import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/webspace_name.dart';
import 'helpers/localized.dart';

void main() {
  testWidgets(
    'the glyph picker lays its glyphs out in a grid about as tall as it is '
    'wide, desktop\'s smaller buttons included (WEBSPACE-016)',
    (tester) async {
      await pumpLocalized(
        tester,
        size: const Size(1280, 800),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                unawaited(pickWebspaceGlyph(context, current: null)),
            child: const Text('pick'),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      final glyphs = [
        for (final element in find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(IconButton),
            )
            .evaluate())
          tester.getRect(find.byElementPredicate((e) => e == element)),
      ];
      expect(glyphs, hasLength(WebspaceGlyph.values.length));
      final columns = {for (final rect in glyphs) rect.left.round()}.length;
      final rows = {for (final rect in glyphs) rect.top.round()}.length;
      expect(
        (columns, rows),
        (5, 4),
        reason: '${WebspaceGlyph.values.length} glyphs, about square',
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
    }),
  );
}
