import 'dart:math' as math;

import 'package:webspace/services/page_js.dart';

/// Which channel a site's zoom rides on. Exactly one owns page scale for
/// a given site; see BUG-008 for why mixing them does not work.
enum PageZoomChannel {
  /// 100%: no zoom shim at all, and no native setting is touched.
  none,

  /// Mobile, outside desktop mode: `<meta name="viewport">`.
  viewportMeta,

  /// Desktop engines, and mobile under desktop mode (which owns the
  /// viewport meta itself): root CSS `zoom`.
  cssZoom,
}

/// The zoom channel for one site plus the knobs that must agree with it.
class PageZoomPlan {
  const PageZoomPlan(this.channel, {this.pinLayoutWidth = false});

  final PageZoomChannel channel;

  /// Emit an explicit layout `width` next to `initial-scale`. Android
  /// only — see lib/js/page_zoom_viewport.js.
  final bool pinLayoutWidth;

  /// Android's `useWideViewPort`, without which the meta's layout width is
  /// ignored. Set only when the viewport channel is actually in use.
  bool get needsWideViewPort =>
      channel == PageZoomChannel.viewportMeta && pinLayoutWidth;
}

/// Pick the zoom channel for a site. Pure: the caller supplies the
/// platform so this stays testable off-device.
PageZoomPlan planPageZoom({
  required int zoomPercent,
  required bool isAndroid,
  required bool isIOS,
  required bool desktopMode,
}) {
  if (zoomPercent == 100) return const PageZoomPlan(PageZoomChannel.none);
  if ((isAndroid || isIOS) && !desktopMode) {
    return PageZoomPlan(PageZoomChannel.viewportMeta,
        pinLayoutWidth: isAndroid);
  }
  return const PageZoomPlan(PageZoomChannel.cssZoom);
}

/// The mobile page-zoom shim (viewport meta) for [zoomPercent], described in
/// lib/js/page_zoom_viewport.js. [pinLayoutWidth] is Android's explicit
/// layout width; [portraitWidth] and [landscapeWidth] are the view's CSS-pixel
/// width in each orientation, 0 when unknown.
String buildPageZoomViewportShim({
  required int zoomPercent,
  required bool pinLayoutWidth,
  double portraitWidth = 0,
  double landscapeWidth = 0,
}) =>
    PageJs.pageZoomViewport.withConfig({
      'scale': zoomPercent / 100,
      'pinLayoutWidth': pinLayoutWidth,
      'portraitWidth': math.max(0, portraitWidth.floor()),
      'landscapeWidth': math.max(0, landscapeWidth.floor()),
    });

/// Per-site page zoom through CSS `zoom`, for the engines that ignore the
/// viewport meta (desktop) or where desktop mode owns it.
String buildPageZoomCssShim(int zoomPercent) =>
    PageJs.pageZoomCss.withConfig({'zoomPercent': zoomPercent});

/// The OS text size on WebKit, which has no `textZoom` setting.
String buildTextZoomShim(int zoomPercent) =>
    PageJs.textZoom.withConfig({'zoomPercent': zoomPercent});

/// Per-site page-zoom bounds (percent). Mirrors the range desktop browsers
/// expose; 100 is unscaled.
const int kMinZoomPercent = 30;

const int kMaxZoomPercent = 300;

const int kDefaultZoomPercent = 100;

int clampZoomPercent(int value) =>
    value.clamp(kMinZoomPercent, kMaxZoomPercent);
