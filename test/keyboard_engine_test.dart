import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/keyboard_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/site_ids.dart';

final _a = SiteId('site-a');
final _b = SiteId('site-b');
final _t1 = TabId('t1');
final _t2 = TabId('t2');

void main() {
  group('NAV-021 the keyboard leaves with the page that raised it', () {
    test('another site, another tab and the webspaces each hide it', () {
      final from = (site: _a, tab: _t1);
      for (final to in [
        (site: _b, tab: _t1),
        (site: _a, tab: _t2),
        (site: null, tab: null),
      ]) {
        expect(
          planKeyboard(FaceChanged(from: from, to: to), focus: FocusOwner.page),
          (blur: null, hide: true),
          reason: 'from $from to $to',
        );
      }
    });

    test('a rebuild that shows the same page hides nothing', () {
      final face = (site: _a, tab: _t1);
      expect(
        planKeyboard(FaceChanged(from: face, to: face), focus: FocusOwner.page),
        (blur: null, hide: false),
      );
    });

    test('a cover blurs the page still under it and hides the keyboard', () {
      expect(
        planKeyboard(Covered(face: (site: _a, tab: _t1)), focus: FocusOwner.page),
        (blur: _a, hide: true),
      );
      expect(
        planKeyboard(Covered(face: (site: null, tab: null)), focus: FocusOwner.page),
        (blur: null, hide: true),
        reason: 'the webspaces have no page to blur',
      );
    });

    test('a field of a screen over the page keeps its own keyboard', () {
      for (final event in [
        FaceChanged(from: (site: _a, tab: _t1), to: (site: _b, tab: _t1)),
        Covered(face: (site: _a, tab: _t1)),
      ]) {
        expect(planKeyboard(event, focus: FocusOwner.screenOver),
            (blur: null, hide: false),
            reason: '$event');
      }
    });
  });
}
