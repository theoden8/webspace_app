# Site Permission Badges Specification

## Purpose

Make it visible, at a glance in the drawer, which sites currently hold a
capture or background-playback grant. Those grants are per-site, settled
once (from a popup or the settings screen) and then applied silently
forever after — so without a surface that names them, a user who allowed
their camera on one banking site months ago has no way to notice it short
of opening every site's settings.

The badges are a *read-only projection* of state other specs own:

- [`per-site-location`](../per-site-location/spec.md) — `locationMode`
- [`web-camera-access`](../web-camera-access/spec.md) — `cameraMode`
- [`web-microphone-access`](../web-microphone-access/spec.md) — `microphoneMode`
- [`background-audio`](../background-audio/spec.md) — `backgroundAudioEnabled`

They add no state, no persistence and no decision of their own. Two kinds
of grant are distinguished, because they differ in what the site can
actually observe:

- **Real device access** — the OS opens a sensor for the site (live
  location fix, device camera). Rendered in the theme's error color.
- **Simulated access** — the app satisfies the request with data the user
  supplied (static coordinates, a picked image/video, a looped audio
  clip); no device is opened. Rendered muted. There is no real-microphone
  mode in the app (MIC-001), so every microphone badge is of this kind.

## Status

- **Status**: Completed

---

## Requirements

### Requirement: PERMBADGE-001 — Badge Set Derives From Effective Per-Site State

`sitePermissionBadges(WebViewModel)`
([lib/widgets/site_permission_badges.dart](../../../lib/widgets/site_permission_badges.dart))
SHALL return exactly the grants the site currently holds, in the fixed
order location, camera, microphone, background audio:

| Badge | Condition |
|---|---|
| `realLocation` | `locationMode == LocationMode.live` |
| `spoofLocation` | `locationMode == LocationMode.spoof` |
| `realCamera` | `effectiveCameraMode == CameraAccessMode.real` |
| `virtualCamera` | `effectiveCameraMode == CameraAccessMode.virtual` |
| `virtualMicrophone` | `effectiveMicrophoneMode == MicrophoneAccessMode.virtual` |
| `backgroundAudio` | `effectiveBackgroundAudioEnabled` |

Undecided (`ask`), denied (`block`) and `LocationMode.off` SHALL produce
no badge: a badge means "this site has been granted something", never
"this site once asked". The `effective*` getters are read, never the raw
fields, so an archive-tier site (ARCH-006) shows no badge for a grant the
archive fold disables while the stored intent survives underneath.

#### Scenario: A site with no grants shows nothing

**Given** a site with `locationMode == off`, `cameraMode == ask`, `microphoneMode == ask` and background audio off
**When** its drawer tile renders
**Then** no permission badge is drawn

#### Scenario: Blocked is not a grant

**Given** a site with `cameraMode == block` and `microphoneMode == block`
**When** its drawer tile renders
**Then** no permission badge is drawn

#### Scenario: Every grant is surfaced in a stable order

**Given** a site with `locationMode == live`, `cameraMode == real`, `microphoneMode == virtual` and background audio on
**When** its drawer tile renders
**Then** the badges read location, camera, microphone, background audio in that order

#### Scenario: Archive-tier sites show no capture badge

**Given** an archive-tier site whose stored `cameraMode == real`, `microphoneMode == virtual` and background audio on
**When** its drawer tile renders
**Then** no badge is drawn, because the effective modes are `block` / `block` / off
**And** the stored modes are unchanged for when the site leaves the archive

### Requirement: PERMBADGE-002 — Real Device Access Reads Differently From Simulated

A badge for a grant that opens a real device (`realLocation`,
`realCamera`) SHALL render with the filled glyph in
`ColorScheme.error`; a badge for a grant the app satisfies synthetically
(`spoofLocation`, `virtualCamera`, `virtualMicrophone`) and the
background-audio badge SHALL render with an outlined glyph in
`ColorScheme.onSurfaceVariant`. No two badges SHALL share a glyph.

#### Scenario: A simulated camera does not look like an open camera

**Given** one site with `cameraMode == real` and another with `cameraMode == virtual`
**When** both drawer tiles render
**Then** the first shows a filled camera glyph in the error color
**And** the second shows an outlined camera glyph in the muted color

### Requirement: PERMBADGE-003 — Badges Are Labelled From The Settings Strings

Each badge SHALL carry a `semanticLabel` of the form
`<setting name>: <selected value>` (background audio, which is a
boolean, uses its setting name alone), composed from the same
`AppLocalizations` keys the per-site settings screen renders. No badge
introduces new user-facing copy, so a badge can never describe a grant
differently from the screen that sets it. The strip SHALL NOT install a
`Tooltip` or any other gesture recognizer: it sits inside the tile's
long-press gestures (context menu, drag-to-reorder) and must not compete
with them.

#### Scenario: Screen-reader users get the grant named

**Given** a site with `cameraMode == real`
**When** its badge is read by a screen reader
**Then** the label is `siteSettingsCameraAccess` + ": " + `siteSettingsCameraAccessAllow`

### Requirement: PERMBADGE-004 — Both Drawer Tile Paths Show Badges

The drawer renders site tiles through one shared content builder
(`_buildSiteGridTileContent` in [lib/main.dart](../../../lib/main.dart)),
used by both the reorderable (drag-enabled) and static tile paths, so a
grant is equally visible whichever path is active and in either tile
layout (narrow icon-over-name, wide icon-beside-name). In the narrow
layout the badge strip is anchored to the favicon's bottom edge, which is
the only place with room; the tile's height is unchanged by the badges.

#### Scenario: Reordering does not hide grants

**Given** a webspace whose sites can be reordered by drag
**When** the drawer renders a site holding a camera grant
**Then** its badge is drawn, exactly as in a non-reorderable webspace
