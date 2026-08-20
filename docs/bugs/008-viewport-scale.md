# BUG-008 — Page renders at the wrong viewport scale

Status: open

## Symptom

A page displays at the wrong magnification and does not recover on its
own. Faces seen so far:

- A site loads zoomed out and stays stuck at a fractional scale
  (observed 0.73 on github.com on iOS) until a manual reload.
- With per-site page zoom below 100%, the page shrinks into empty
  gutters instead of reflowing to fill the screen.
- With the inverse-width compensation for those gutters, content is
  pushed off-screen horizontally on newer Android System WebViews.
- With per-site page zoom at anything other than 100%, every site
  renders its desktop layout on Android.
- Root CSS `zoom` applied at document start can leave Blink painting a
  blank frame until a layout invalidation lands (overlaps BUG-001's
  white-screen symptom).

## Root mechanism / invariant

On mobile engines (Blink and WebKit), the layout viewport width and the
page scale are owned by the `<meta name="viewport">` / `initial-scale`
channel. Any app code that sets, compensates, or neglects page scale
through a different channel behaves engine- or engine-version-dependently:

- CSS `zoom` on the root scales without reflowing on older Blink
  (gutters) and reflows on newer Blink, so any compensation tuned for
  one semantic breaks on the other.
- WebKit picks its own scale (~980px default, zoom-to-fit) whenever a
  page reaches first layout without an `initial-scale`, then latches it
  and does not cleanly reset when a meta arrives later.
- Android System WebView resolves the same meta through its own quirk
  path (`PageScaleConstraintsSet::AdjustForAndroidWebViewQuirks`), not
  the CSS Device Adaptation rules WebKit and desktop Chromium follow, so
  a directive set that is correct on one engine can mean something else
  entirely there.
- Timing matters: the meta must be correct before first layout.
  DOMContentLoaded is too late to undo WebKit's latch; only
  DOCUMENT_START plus a MutationObserver catches late-inserted metas in
  time.

The invariant: **on Android and iOS, page scale must be driven through
the viewport meta (`initial-scale`), written at DOCUMENT_START and
re-asserted by a MutationObserver; no other channel (CSS `zoom`, width
compensation, repaint nudges) may own scale there.** Desktop engines
ignore the viewport meta, so they are the one place the CSS `zoom` path
is correct. Desktop mode owns the viewport meta via its own shim and
must stay the single writer there. One channel, but not one shape: the
`width` directive that goes with the scale is per-engine — WebKit derives
the layout width from `initial-scale` alone, Android System WebView
falls back to 980px unless the width is spelled out.

The normative rules live in
[openspec/specs/page-zoom/spec.md](../../openspec/specs/page-zoom/spec.md)
(ZOOM-001..006, added with attempt 5); the viewport ownership rule in
desktop mode is specced in
[openspec/specs/desktop-mode/spec.md](../../openspec/specs/desktop-mode/spec.md).
Diagnostic probes from the #461 investigation live in `test/fixtures/`
(moved there by #466).

## Fix attempts

1. **2026-06-13 — PR #420, `fc17b79` (superseded in-PR).** For per-site
   zoom, widened the root element by the inverse zoom factor so CSS
   `zoom` scales an expanded layout back to full width, plus a
   reflow-and-resize nudge on load for Blink's blank frame. *Why
   partial*: assumed the non-reflowing CSS `zoom` semantic. Newer
   Android System WebViews reflow `zoom` natively, so the inverse-width
   compensation overshot and pushed content off-screen horizontally.
   The scale channel was still CSS, not the viewport.

2. **2026-06-22 — PR #420, `78b97d2` (open, unmerged).** Moved mobile
   per-site zoom onto the viewport channel: rewrite every viewport meta
   to `initial-scale=z` with no `width` directive so the engine derives
   layout width as deviceWidth/z and reflows; `useWideViewPort` enabled
   on Android for the meta to be honoured; desktop engines and
   desktop-mode sites keep the CSS `zoom` path. *Why partial*: covers
   the zoom feature only, not load-time scale on unzoomed sites (next
   two attempts); its MutationObserver watches added nodes but not
   attribute mutations of an existing meta (see gaps).

3. **2026-06-27 — PR #452.** For unzoomed sites loading zoomed out on
   WebKit, injected a `width=device-width` viewport at DOMContentLoaded
   when the page declares none. *Why partial*: DOMContentLoaded lands
   after WebKit latches the stuck scale, so it fixed only pages whose
   meta never arrives, and missed the larger class of pages declaring
   `width=device-width` without `initial-scale` (Turbo/PJAX SPAs, the
   Universal-Link cancel+reissue path).

4. **2026-07-05 — PR #461, `1f61073`.** Replaced #452's fill with a
   DOCUMENT_START normalizer ensuring every viewport meta carries
   `initial-scale=1` (appending to a width-only meta, injecting a full
   meta when none ships), re-applied via a MutationObserver; pages
   setting their own `initial-scale` are untouched. WebKit-only, since
   Android pins the scale natively via `useWideViewPort`. *Why
   partial*: normalizes to scale 1 only; the per-site zoom feature
   still ran on the CSS channel until attempt 2, and the two shims'
   coexistence relies on the normalizer skipping any meta that already
   names `initial-scale`.

5. **2026-08-20 — issue #419 follow-up.** Attempt 2 shipped in 0.30 and
   the field reported the opposite failure: on Android, any zoom other
   than 100% served the site's desktop layout. Cause is the meta shape
   attempt 2 chose. Android System WebView hardcodes
   `wide_viewport_quirk`, and with `useWideViewPort` on (which attempt 2
   also turned on, for the meta to be honoured at all)
   `PageScaleConstraintsSet::AdjustForAndroidWebViewQuirks` replaces the
   layout width with the UA fallback — 980px, from `ViewportStyleResolver`
   in the kMobile style — whenever the meta names a scale other than 1
   and no width. Extend-to-zoom never runs; every site lays out at 980px
   and resolves its desktop breakpoints. Fix: on Android spell the layout
   width out — `width=floor(min(screen.width, innerWidth) / z)`, the
   number extend-to-zoom would have derived — which makes `max_width`
   fixed so neither quirk branch fires. Only the quirk needs the number
   present: `ViewportDescription::Resolve` still raises anything below the
   true extend-to-zoom width back to it (the width directive implies
   `min-width: extend-to-zoom`), so the shim errs low on purpose. WebKit
   keeps the width-less meta — it has no such quirk, and extend-to-zoom
   sizes against the real WebView (iPad Split View, Stage Manager), which
   nothing outside the engine tracks. The shim moved to a pure-Dart builder
   (`lib/services/page_zoom_shim.dart`) so the emitted directives are
   gated in CI by `test/js/page_zoom_viewport.test.js`, and the width is
   derived from Flutter's view extents plus a single pre-meta
   `innerWidth` sample — never `screen.*`, which the anti-fingerprinting
   shim redefines ahead of this one (pinned 1920, or mirrored to
   `innerWidth` under letterbox; either would compound the zoom on
   re-application). Coverage went to four tiers, and page zoom finally got
   a spec (ZOOM-001..006): Dart channel matrix, jsdom directives, real
   Blink layout (`test/browser/page_zoom_real_engine.test.js`, which also
   pins that the Android width and the WebKit meta resolve to the same
   layout), and `integration_test/page_zoom_test.dart` on WPE, WKWebView
   and the Android emulator. *Why partial*: covers the Android layout
   width only. The width still comes from the view, not the WebView's own
   box (see gaps), and the MutationObserver gap below is still open.

## Known open gaps

- The pinned Android layout width is derived from Flutter's view extents
  and one pre-meta `innerWidth` sample. Both are the right box in the
  common case and neither is measured continuously: a WebView that is
  resized after load without a rotation (split-screen drag, freeform
  window) keeps the width it was pinned at, and the re-derivation on
  `resize` falls back to the view extent for the new orientation. Erring
  low keeps that safe — the engine raises an under-estimate back to the
  exact extend-to-zoom width — but an over-estimate would overflow.
  Measuring the WebView itself means pushing the width in natively on
  every resize.
- Tracking Protection's `screen.*` spoof and the zoom shim are only
  proven not to interfere at the jsdom/Dart tier (the shim never reads
  `screen`); no integration case runs a zoomed site with ETP on.
- `buildPageZoomViewportShim`'s MutationObserver only watches added
  nodes. A site that rewrites the `content` attribute of its existing
  viewport meta after load (responsive frameworks, orientation
  handlers) reverts the zoom until the next navigation. The #461
  normalizer already watches attribute mutations; the zoom script does
  not.
- Desktop-mode sites with zoom set take the CSS `zoom` path inside
  desktop mode's fixed-width viewport; that interaction has no test.
- Desktop engines keep CSS `zoom` plus the reflow/resize nudge for
  Blink's blank-frame quirk; the nudge is a workaround, not a fix, and
  the quirk's mechanism is unconfirmed upstream.
- The #461 normalizer is skipped in desktop mode by design, but nothing
  structural prevents a future third writer to the viewport meta;
  single-writer ownership is enforced only by convention.
