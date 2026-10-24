import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/widgets/site_grid_tile.dart';

import 'helpers/localized.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'a look-alike keeps its tab-tree color when selected in ${brightness.name} (WEBSPACE-004, WEBSPACE-014)',
      (tester) async {
        final site = WebViewModel(
          initUrl: 'https://example.test',
          customIconPng: Uint8List.fromList(
            image.encodePng(image.Image(width: 2, height: 2)),
          ),
        )..containerColor = 4;
        Color? background;
        for (final selected in [false, true]) {
          await pumpLocalized(
            tester,
            theme: ThemeData(
              colorScheme: buildAccentColorScheme(
                accentBlue,
                brightness: brightness,
              ),
            ),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  height: 180,
                  child: SiteGridTile(
                    site: site,
                    listIndex: 0,
                    selected: selected,
                    showTabCount: false,
                    layout: SiteGridTileLayout.library,
                    lookalike: true,
                    onOpen: () {},
                    onMenu: (_, {required globalPosition}) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final well = tester.widget<AnimatedContainer>(
            find.byType(AnimatedContainer),
          );
          final decoration = well.decoration! as BoxDecoration;
          expect(
            (decoration.border! as Border).top.color,
            containerColorOf(site, brightness: brightness),
          );
          if (selected) {
            expect(decoration.color, background);
          } else {
            background = decoration.color;
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'a site\'s icon carries its container colour only where another site '
    'shows the same icon, or it has none (WEBSPACE-014)',
    (tester) async {
      Future<BoxDecoration> well(
        WebViewModel site, {
        required bool lookalike,
      }) async {
        await pumpLocalized(
          tester,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 180,
                child: SiteGridTile(
                  key: UniqueKey(),
                  site: site,
                  listIndex: 0,
                  selected: false,
                  showTabCount: false,
                  layout: SiteGridTileLayout.library,
                  lookalike: lookalike,
                  onOpen: () {},
                  onMenu: (_, {required globalPosition}) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester
                .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration!
            as BoxDecoration;
      }

      final own = WebViewModel(
        initUrl: 'https://example.test',
        customIconPng: Uint8List.fromList(
          image.encodePng(image.Image(width: 2, height: 2)),
        ),
      )..containerColor = 4;
      final theme = ThemeData();
      final plain = await well(own, lookalike: false);
      expect(plain.border, isNull, reason: 'its icon tells it apart');
      expect(plain.color, theme.colorScheme.surfaceContainerHighest);
      final alike = await well(own, lookalike: true);
      expect(
        (alike.border! as Border).top.color,
        containerColorOf(own, brightness: Brightness.light),
      );
      expect(alike.color, isNot(plain.color));
      final file = WebViewModel(initUrl: 'file:///notes.html')
        ..containerColor = 2;
      final none = await well(file, lookalike: false);
      expect(
        (none.border! as Border).top.color,
        containerColorOf(file, brightness: Brightness.light),
        reason: 'a globe tells no site apart',
      );
      expect(
        FaviconUrlCache.isMissing(file.initUrl),
        isTrue,
        reason: 'a card made for it next knows from its first frame',
      );
      expect(tester.takeException(), isNull);
    },
  );

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
