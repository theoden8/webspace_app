import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/site_drawer.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_permission_badges.dart';

import 'helpers/localized.dart';

/// PERMBADGE-004: a site holding a grant shows its badge in the drawer
/// whether the drawer's sites can be reordered or not, and in both of the
/// tile's layouts.
void main() {
  WebViewModel filming() => WebViewModel(
        initUrl: 'https://call.example',
        name: 'Call',
        captures: const CaptureGrants(
          camera: (mode: CameraAccessMode.real, source: null),
          microphone: (mode: MicrophoneAccessMode.ask, source: null),
          screenShare: (mode: ScreenShareMode.ask, source: null),
        ),
      );

  Finder cameraBadgeIn(Finder tile) => find.descendant(
      of: tile,
      matching: find.descendant(
          of: find.byType(SitePermissionBadges),
          matching: find.byIcon(Icons.videocam)));

  for (final reorderable in [true, false]) {
    testWidgets('PERMBADGE-004: the drawer draws a camera grant, '
        '${reorderable ? '' : 'not '}reorderable', (tester) async {
      final sites = [filming(), WebViewModel(initUrl: 'https://plain.example')];
      await pumpLocalized(tester,
          size: const Size(400, 800),
          home: Scaffold(
            body: SiteDrawer(
              accentColor: AccentColor.values.first,
              webspace: Webspace(name: 'All'),
              models: sites,
              order: const [0, 1],
              current: null,
              showsTabCount: (_) => false,
              onBackToWebspaces: () {},
              onOpen: (_) {},
              onMenu: (_, {required site, required position}) {},
              onReorder: reorderable ? (_, {required to}) {} : null,
              onAddSite: () {},
            ),
          ));
      await tester.pumpAndSettle();

      final tiles = find.byType(SiteGridTile);
      expect(tiles, findsNWidgets(2));
      expect(cameraBadgeIn(tiles.at(0)), findsOneWidget);
      expect(cameraBadgeIn(tiles.at(1)), findsNothing);
    });
  }

  for (final (shape, layout, list, size) in [
    ('drawer', SiteGridTileLayout.compact, 0.0, const Size(120, 96)),
    ('library grid', SiteGridTileLayout.library, 0.0, const Size(140, 180)),
    ('packed library', SiteGridTileLayout.library, 0.0, const Size(100, 140)),
    ('library row', SiteGridTileLayout.library, 1.0, const Size(360, 64)),
  ]) {
    testWidgets('PERMBADGE-004: a $shape tile draws the grant within its own '
        'height', (tester) async {
      Future<Size> tileOf(WebViewModel site) async {
        await pumpLocalized(tester,
            home: Scaffold(
              body: Center(
                child: SizedBox.fromSize(
                  size: size,
                  child: SiteGridTile(
                    site: site,
                    listIndex: 0,
                    selected: false,
                    showTabCount: false,
                    layout: layout,
                    list: list,
                    onOpen: () {},
                    onMenu: (_, {required globalPosition}) {},
                  ),
                ),
              ),
            ));
        await tester.pumpAndSettle();
        return tester.getSize(find.byType(SiteGridTile));
      }

      final plain = await tileOf(WebViewModel(initUrl: 'https://call.example'));
      final granted = await tileOf(filming());
      expect(cameraBadgeIn(find.byType(SiteGridTile)), findsOneWidget);
      expect(granted, plain, reason: 'the badges take no height of their own');
      expect(tester.takeException(), isNull);
    });
  }
}
