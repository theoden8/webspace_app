// Per-site page zoom — mobile (viewport-meta) shim.
//
// Mobile engines own page scale through `<meta name="viewport">`, so the
// zoom feature drives `initial-scale` rather than CSS `zoom` there
// (BUG-008: any other channel is engine-version dependent). Desktop
// engines ignore the meta and keep the CSS `zoom` path in
// `lib/services/webview.dart`.
//
// Two layout-width regimes, one per engine:
//
//   * WebKit (iOS/macOS) — emit `initial-scale=z` alone. With no `width`
//     directive the engine resolves extend-to-zoom, deriving the layout
//     width as `deviceWidth / z`, which is exactly desktop-browser zoom:
//     the page reflows to fill the screen at scale `z`.
//
//   * Android System WebView — the same width-less meta hits Chromium's
//     wide-viewport quirk. `AwSettings` hardcodes `wide_viewport_quirk`,
//     and with `useWideViewPort` on,
//     `PageScaleConstraintsSet::AdjustForAndroidWebViewQuirks` replaces
//     the layout width with the UA fallback (980px, from
//     `ViewportStyleResolver` in the kMobile style) whenever the meta
//     names a scale other than 1 but no width. Every site then lays out
//     at 980px and resolves its desktop breakpoints. So Android gets an
//     explicit `width` — `deviceWidth / z`, the same number extend-to-zoom
//     would have produced — which makes `max_width` fixed and keeps the
//     quirk out of the path. Only the quirk needs the number to be there:
//     `ViewportDescription::Resolve` still raises anything under the true
//     extend-to-zoom width back up to it, so the shim errs low.
//     `useWideViewPort` must stay on for a fixed width to be honoured at
//     all — the quirk's `!use_wide_viewport` branch otherwise clamps the
//     layout back to device width and resets the scale to 1 for z < 1.
//
// Where the device width comes from, and where it must NOT come from:
//
//   * `screen.*` is off limits. The anti-fingerprinting shim (Tracking
//     Protection, on by default) is injected ahead of this one and
//     redefines `Screen.prototype.width` — to a pinned 1920, or to
//     `innerWidth` in letterbox mode. Deriving the layout width from a
//     value that mirrors `innerWidth` would compound the zoom on every
//     re-application.
//   * `innerWidth` is genuine but is the *visual* viewport, so once our
//     own `initial-scale` is in effect it reads `deviceWidth / z`, not
//     `deviceWidth`. It is therefore sampled exactly once, at
//     DOCUMENT_START before the meta is written, where it is the one
//     measure that sees a physically letterboxed or split-screen WebView.
//   * Flutter's view extents, passed in from Dart, cover re-application:
//     they survive rotation (short side vs long side) and cannot be
//     spoofed from the page.

import 'dart:math' as math;

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
  /// only — see the file header.
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

/// Format a zoom factor for embedding in the viewport meta: fixed
/// precision without trailing zeros (`0.8`, `1.25`, `1`).
String trimZoomNum(double v) {
  var s = v.toStringAsFixed(4);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

/// Build the mobile page-zoom shim for [zoomPercent].
///
/// [pinLayoutWidth] emits an explicit layout `width` alongside the scale
/// (Android; see the file header). Leave it false on WebKit, where
/// extend-to-zoom already derives the same width and tracks the real
/// WebView size rather than the display size.
///
/// [portraitWidth] and [landscapeWidth] are the view's CSS-pixel width in
/// each orientation (Flutter's short and long view extents). They are only
/// read when pinning; pass 0 when they are unknown and the shim falls back
/// to its one-shot `innerWidth` sample.
///
/// Rewrites every viewport meta the page ships, injects one when it ships
/// none, and watches for late-inserted metas (SPAs, frameworks) the same
/// way `buildDesktopModeShim` does. Injected at DOCUMENT_START: the meta
/// must be correct before first layout.
String buildPageZoomViewportShim({
  required int zoomPercent,
  required bool pinLayoutWidth,
  double portraitWidth = 0,
  double landscapeWidth = 0,
}) {
  final scale = trimZoomNum(zoomPercent / 100);
  final portrait = math.max(0, portraitWidth.floor());
  final landscape = math.max(0, landscapeWidth.floor());
  return '''
(function(){
  var SCALE=$scale;
  var PIN=$pinLayoutWidth;
  var PORTRAIT=$portrait;
  var LANDSCAPE=$landscape;
  var measured=0;
  var measuredLandscape=false;
  function isLandscape(){
    try{
      if(window.matchMedia){ return !!window.matchMedia('(orientation: landscape)').matches; }
    }catch(e){}
    return false;
  }
  // One sample of the real box, taken before our meta lands: after that
  // innerWidth reports the visual viewport, which our own scale has moved.
  function captureOnce(){
    if(measured!==0) return;
    var w=0;
    try{ w=window.innerWidth||0; }catch(e){}
    measured=w>0?w:-1;
    measuredLandscape=isLandscape();
  }
  function baseWidth(){
    var landscape=isLandscape();
    var b=landscape?LANDSCAPE:PORTRAIT;
    if(!(b>0)){ b=landscape?PORTRAIT:LANDSCAPE; }
    // The sample only describes the orientation it was taken in; after a
    // rotation the view extents are the better answer.
    if(measured>0&&landscape===measuredLandscape){
      b=b>0?Math.min(b,measured):measured;
    }
    return b>0?b:0;
  }
  function layoutWidth(){
    var b=baseWidth();
    return b>0?Math.max(1,Math.floor(b/SCALE)):0;
  }
  function content(){
    if(!PIN) return 'initial-scale='+SCALE;
    var w=layoutWidth();
    return w?('width='+w+', initial-scale='+SCALE):('initial-scale='+SCALE);
  }
  function applyTo(m,c){
    try{ if(m.getAttribute('content')!==c){ m.setAttribute('content',c); } }catch(e){}
  }
  function ensure(){
    try{
      captureOnce();
      var c=content();
      var metas=document.querySelectorAll('meta[name="viewport" i]');
      if(metas.length===0){
        var m=document.createElement('meta');
        m.setAttribute('name','viewport');
        m.setAttribute('content',c);
        (document.head||document.documentElement).appendChild(m);
      } else {
        for(var i=0;i<metas.length;i++){ applyTo(metas[i],c); }
      }
    }catch(e){}
  }
  ensure();
  try{
    var mo=new MutationObserver(function(muts){
      for(var i=0;i<muts.length;i++){
        var added=muts[i].addedNodes; if(!added) continue;
        for(var j=0;j<added.length;j++){
          var n=added[j];
          if(n&&n.nodeType===1&&n.tagName==='META'){
            var nm=n.getAttribute&&n.getAttribute('name');
            if(nm&&nm.toLowerCase()==='viewport'){ applyTo(n,content()); }
          }
        }
      }
    });
    if(document.documentElement){ mo.observe(document.documentElement,{childList:true,subtree:true}); }
    else { document.addEventListener('DOMContentLoaded',function(){ ensure(); mo.observe(document.documentElement,{childList:true,subtree:true}); }); }
  }catch(e){}
  // Rotation swaps which view extent applies, so the meta is re-derived.
  // Nothing in that derivation reads a value our own scale has moved, so
  // re-running cannot compound; applyTo also skips an unchanged value.
  try{
    window.addEventListener('resize',ensure);
    window.addEventListener('orientationchange',ensure);
  }catch(e){}
})();''';
}
