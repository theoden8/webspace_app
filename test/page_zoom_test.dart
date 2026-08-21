// Per-site page zoom: channel selection and the emitted viewport meta.
//
// The behavioural tier for the shim's JS lives in
// test/js/page_zoom_viewport.test.js (jsdom) and
// test/browser/page_zoom_real_engine.test.js (real Blink). This file
// covers the Dart side: which channel a site's zoom rides on, and the
// exact directives the builder emits (BUG-008 — a stripped `width` is
// what put every zoomed Android site on the 980px desktop layout).

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/page_zoom_shim.dart';

PageZoomPlan _plan({
  int zoom = 80,
  bool android = false,
  bool ios = false,
  bool desktopMode = false,
}) =>
    planPageZoom(
      zoomPercent: zoom,
      isAndroid: android,
      isIOS: ios,
      desktopMode: desktopMode,
    );

void main() {
  group('zoom channel selection', () {
    test('100% carries no zoom shim on any platform', () {
      for (final plan in [
        _plan(zoom: 100, android: true),
        _plan(zoom: 100, ios: true),
        _plan(zoom: 100),
        _plan(zoom: 100, android: true, desktopMode: true),
      ]) {
        expect(plan.channel, PageZoomChannel.none);
        expect(plan.needsWideViewPort, isFalse);
      }
    });

    test('Android takes the viewport meta with a pinned layout width', () {
      for (final zoom in [50, 80, 90, 110, 150, 200]) {
        final plan = _plan(zoom: zoom, android: true);
        expect(plan.channel, PageZoomChannel.viewportMeta);
        expect(plan.pinLayoutWidth, isTrue, reason: 'zoom $zoom');
        expect(plan.needsWideViewPort, isTrue, reason: 'zoom $zoom');
      }
    });

    test('iOS takes the viewport meta and leaves the width to the engine', () {
      final plan = _plan(zoom: 80, ios: true);
      expect(plan.channel, PageZoomChannel.viewportMeta);
      expect(plan.pinLayoutWidth, isFalse);
      // useWideViewPort is an Android setting; nothing to flip on WebKit.
      expect(plan.needsWideViewPort, isFalse);
    });

    test('desktop engines take CSS zoom', () {
      final plan = _plan(zoom: 80);
      expect(plan.channel, PageZoomChannel.cssZoom);
      expect(plan.needsWideViewPort, isFalse);
    });

    test('desktop mode keeps CSS zoom on mobile: it owns the viewport meta',
        () {
      for (final plan in [
        _plan(zoom: 80, android: true, desktopMode: true),
        _plan(zoom: 80, ios: true, desktopMode: true),
      ]) {
        expect(plan.channel, PageZoomChannel.cssZoom);
        expect(plan.needsWideViewPort, isFalse);
      }
    });

    test('useWideViewPort is never requested without the viewport channel',
        () {
      for (final zoom in [50, 100, 150]) {
        for (final android in [true, false]) {
          for (final ios in [true, false]) {
            for (final desktop in [true, false]) {
              final plan = _plan(
                zoom: zoom,
                android: android,
                ios: ios,
                desktopMode: desktop,
              );
              if (plan.needsWideViewPort) {
                expect(plan.channel, PageZoomChannel.viewportMeta);
                expect(plan.pinLayoutWidth, isTrue);
              }
            }
          }
        }
      }
    });
  });

  group('scale formatting', () {
    test('drops trailing zeros and the bare decimal point', () {
      expect(trimZoomNum(0.8), '0.8');
      expect(trimZoomNum(1.0), '1');
      expect(trimZoomNum(1.25), '1.25');
      expect(trimZoomNum(0.5), '0.5');
      expect(trimZoomNum(2.5), '2.5');
      expect(trimZoomNum(0.33), '0.33');
    });

    test('never emits exponent or long-tail float noise', () {
      for (var percent = 25; percent <= 300; percent += 5) {
        final s = trimZoomNum(percent / 100);
        expect(s, matches(RegExp(r'^\d+(\.\d{1,4})?$')),
            reason: '$percent% formatted as "$s"');
        expect(double.parse(s), closeTo(percent / 100, 0.0001));
      }
    });
  });

  group('viewport meta builder', () {
    String android(int percent) => buildPageZoomViewportShim(
          zoomPercent: percent,
          pinLayoutWidth: true,
          portraitWidth: 393,
          landscapeWidth: 851,
        );
    String webkit(int percent) => buildPageZoomViewportShim(
          zoomPercent: percent,
          pinLayoutWidth: false,
          portraitWidth: 393,
          landscapeWidth: 851,
        );

    test('carries the scale as a decimal factor, not a percentage', () {
      expect(android(80), contains('var SCALE=0.8;'));
      expect(android(125), contains('var SCALE=1.25;'));
      expect(webkit(50), contains('var SCALE=0.5;'));
    });

    test('the Android build emits a width directive; WebKit does not', () {
      expect(android(80), contains("'width='+w+', initial-scale='"));
      expect(android(80), contains('var PIN=true;'));
      expect(webkit(80), contains('var PIN=false;'));
    });

    test('the width is derived from the device, never from a constant', () {
      final js = android(80);
      expect(js, contains('var PORTRAIT=393;'));
      expect(js, contains('var LANDSCAPE=851;'));
      expect(js, contains('window.innerWidth'));
      expect(js, contains('Math.floor'));
    });

    test('never reads screen.*: the anti-fingerprinting shim owns it', () {
      // That shim is injected first and redefines Screen.prototype.width
      // (pinned 1920, or mirrored to innerWidth under letterbox). A layout
      // width derived from it compounds the zoom on every re-application.
      final screenAccess = RegExp(
          r'(window|globalThis)\s*\.\s*screen|\bScreen\s*\.\s*prototype'
          r'|[^a-z]screen\s*\.\s*(width|height|avail)');
      for (final js in [android(80), android(150), webkit(80)]) {
        expect(screenAccess.hasMatch(js), isFalse);
      }
    });

    test('view extents are floored into the script, never emitted as fractions',
        () {
      final js = buildPageZoomViewportShim(
        zoomPercent: 80,
        pinLayoutWidth: true,
        portraitWidth: 392.7,
        landscapeWidth: 850.2,
      );
      expect(js, contains('var PORTRAIT=392;'));
      expect(js, contains('var LANDSCAPE=850;'));
    });

    test('missing view extents degrade to the innerWidth sample', () {
      final js = buildPageZoomViewportShim(
        zoomPercent: 80,
        pinLayoutWidth: true,
      );
      expect(js, contains('var PORTRAIT=0;'));
      expect(js, contains('var LANDSCAPE=0;'));
      expect(js, contains('window.innerWidth'));
    });

    test('re-asserts the meta after load and on viewport changes', () {
      final js = android(80);
      expect(js, contains('MutationObserver'));
      expect(js, contains("addEventListener('resize'"));
      expect(js, contains("addEventListener('orientationchange'"));
    });

    test('every emitted meta names an initial-scale', () {
      // A viewport meta without one lets WebKit pick its own scale and
      // latch it (BUG-008, attempt 4).
      for (final js in [android(80), android(150), webkit(80), webkit(150)]) {
        expect(js, contains("'initial-scale='+SCALE"));
      }
    });
  });
}
