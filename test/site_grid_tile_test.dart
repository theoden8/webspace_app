import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';

import 'helpers/localized.dart';

void main() {
  testWidgets(
    'a launcher item opens its menu after release and on right click',
    (tester) async {
      final site = WebViewModel(
        initUrl: 'https://example.test',
        customIconPng: Uint8List.fromList(
          image.encodePng(image.Image(width: 2, height: 2)),
        ),
      );
      var menus = 0;
      await pumpLocalized(
        tester,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 180,
              child: SiteGridTile(
                site: site,
                listIndex: 0,
                selected: false,
                showTabCount: false,
                layout: SiteGridTileLayout.library,
                onOpen: () {},
                onMenu: (_, {required globalPosition}) => menus++,
                onReorder: null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(SiteGridTile));
      final touch = await tester.startGesture(center);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      expect(
        menus,
        0,
        reason: 'the pointer finishes before the menu covers the item',
      );
      await touch.up();
      await tester.pumpAndSettle();
      expect(menus, 1);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.down(center);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(menus, 2);
    },
  );
}
