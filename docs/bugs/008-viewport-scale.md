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
must stay the single writer there.

No OpenSpec slug owns page zoom yet; the viewport ownership rule in
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

## Known open gaps

- PR #420 (attempts 1–2) is not merged; the mobile viewport-zoom path
  has CI coverage but no field exposure yet.
- `_pageZoomViewportScript`'s MutationObserver only watches added
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
