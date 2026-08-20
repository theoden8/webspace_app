# Page Zoom Specification

## Purpose

Per-site browser-style page zoom: at zoom `z`, the site lays out into
`1/z` as much CSS width as it would at 100% and is drawn at scale `z`, so
the window stays full and content reflows — the same thing a desktop
browser's zoom does. Zoom is a per-site setting (`zoomPercent` on
`WebViewModel`, 100 by default).

Page scale on a mobile engine is owned by `<meta name="viewport">`; on a
desktop engine, by root CSS `zoom`. Both channels are in use, one per
platform, and exactly one may be active for a given site — the lineage of
what goes wrong when that is violated is
[`docs/bugs/008-viewport-scale.md`](../../../docs/bugs/008-viewport-scale.md).

System *text* zoom (the OS font-size accessibility setting) is a separate
mechanism and is not covered here.

## Status

- **Status**: Implemented

---

## Requirements

### Requirement: ZOOM-001 - Zoom reflows, never shrinks

At any zoom other than 100%, a site SHALL lay out into `deviceWidth / z`
CSS pixels of layout viewport and fill the window at scale `z`. The page
SHALL NOT be scaled into empty gutters, laid out at a fallback width, or
pushed off-screen horizontally.

#### Scenario: Zooming out fits more content

**Given** a site set to 80% zoom
**When** the page loads
**Then** the layout viewport is 1.25x the width it has at 100%
**And** 1.25x as much fixed-width content fits across the window
**And** the page does not scroll horizontally

#### Scenario: Zooming in fits less content

**Given** a site set to 150% zoom
**When** the page loads
**Then** the layout viewport is 2/3 of the width it has at 100%
**And** the page does not scroll horizontally

---

### Requirement: ZOOM-002 - One channel per platform

The zoom channel SHALL be chosen by platform, and the other channel SHALL
stay untouched for that site:

1. Android and iOS, outside desktop mode: the viewport meta.
2. Desktop engines, and mobile under desktop mode (whose shim owns the
   viewport meta): root CSS `zoom`.
3. At 100%: neither — no zoom shim is injected and no native zoom-related
   setting is changed.

#### Scenario: Mobile site keeps the CSS channel clean

**Given** an Android or iOS site at 80% zoom
**When** the page loads
**Then** its viewport meta carries `initial-scale=0.8`
**And** the computed root `zoom` is unchanged

#### Scenario: Desktop-mode site keeps the viewport channel clean

**Given** a site with desktop mode on and 80% zoom
**When** the page loads
**Then** the zoom is applied through root CSS `zoom`
**And** the page-zoom shim writes no viewport meta

---

### Requirement: ZOOM-003 - Android pins the layout width

On Android the viewport meta SHALL name an explicit layout `width`
alongside `initial-scale`, and `useWideViewPort` SHALL be enabled for
that site.

A meta that names a scale other than 1 and no width triggers Chromium's
wide-viewport quirk (`PageScaleConstraintsSet::AdjustForAndroidWebViewQuirks`,
enabled unconditionally by `AwSettings`), which replaces the layout width
with the 980px UA fallback — every zoomed site then resolves its desktop
breakpoints. Disabling `useWideViewPort` instead is not a fix: the same
quirk's other branch clamps the layout back to device width and resets
the scale to 1 below 100%.

#### Scenario: A phone at 80% keeps its mobile layout

**Given** an Android site at 80% zoom on a 400px-wide device
**When** the page loads
**Then** the layout viewport is 500px, not 980px
**And** a `(min-width: 768px)` media query does not match

#### Scenario: The pin agrees with the engine

**Given** the same zoom on Android and on WebKit
**When** each engine resolves its viewport meta
**Then** both land on the same layout width

---

### Requirement: ZOOM-004 - The pinned width is derived, never guessed

The pinned width SHALL be derived from the device's own extents and SHALL
NOT exceed `deviceWidth / z`; an under-estimate is raised back to the
engine's extend-to-zoom width, an over-estimate pushes content
off-screen. The shim SHALL NOT read `screen.*`, which the
anti-fingerprinting shim redefines (pinned 1920, or mirrored to
`innerWidth` under letterbox) before the zoom shim runs, and SHALL sample
`innerWidth` only once, before its own meta is written — afterwards that
property reports the zoomed visual viewport.

#### Scenario: Re-applying the meta does not compound the zoom

**Given** a zoomed site whose viewport meta has been applied
**When** the shim re-derives the meta after a resize
**Then** the pinned width is unchanged

#### Scenario: A physically smaller WebView wins

**Given** a WebView narrower than the device (letterbox, split screen)
**When** the shim pins the layout width
**Then** it pins against the WebView's width, not the device's

---

### Requirement: ZOOM-005 - The meta survives the page

The zoom shim SHALL be injected at DOCUMENT_START, SHALL rewrite every
viewport meta the page ships, SHALL inject one when the page ships none,
and SHALL re-apply to metas inserted later (SPAs, frameworks) and after
an orientation change.

#### Scenario: A late-inserted meta is corrected

**Given** a zoomed site whose framework inserts a viewport meta after load
**When** the meta is added to the document
**Then** the shim rewrites it to the site's zoom

#### Scenario: Rotation re-derives the width

**Given** a zoomed Android site in portrait
**When** the device rotates to landscape
**Then** the pinned width is re-derived from the landscape extent

---

### Requirement: ZOOM-006 - Coverage

The zoom contract SHALL be gated at every tier that can see it:

1. Dart (`test/page_zoom_test.dart`) — channel selection per platform and
   the emitted directives.
2. jsdom (`test/js/page_zoom_viewport.test.js`) — what the shim writes,
   including that it never reads `screen.*`.
3. Real Blink (`test/browser/page_zoom_real_engine.test.js`) — the layout
   viewport, breakpoints, overflow, and that the Android pin and the
   WebKit meta resolve to the same layout.
4. Real engines (`integration_test/page_zoom_test.dart`) — the reflow
   contract on WPE (Linux job), WKWebView (macOS job) and Android System
   WebView (emulator job, `scripts/run_android_page_zoom_tests.sh`), which
   is the only engine with the wide-viewport quirk.

#### Scenario: A dropped width directive fails CI

**Given** a change that stops pinning the layout width on Android
**When** the test suites run
**Then** the jsdom quirk guard and the Android integration tier fail
