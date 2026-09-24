# Site Permission Badges Specification

## Purpose

Make it visible, at a glance in the drawer, which sites currently hold a
permission or background-playback grant. Those grants are per-site, settled
once (from a popup or the settings screen) and then applied silently
forever after — so without a surface that names them, a user who allowed
their camera on one banking site months ago has no way to notice it short
of opening every site's settings.

The badges are a *read-only projection* of state other specs own:

- [`per-site-location`](../per-site-location/spec.md) — `locationMode`
- [`web-camera-access`](../web-camera-access/spec.md) — `cameraMode`
- [`web-microphone-access`](../web-microphone-access/spec.md) — `microphoneMode`
- [`web-push-notifications`](../web-push-notifications/spec.md) — `notificationsEnabled`
- `protectedContentAllowed` (Android's DRM permission, set from the same
  Permissions screen)
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
order location, camera, microphone, screen sharing, notifications, protected
content, background audio. That is every grant the site settings'
Permissions row counts as held, in the row's order, plus background audio:
a user who sees a grant listed in the row finds the same grant badged in the
drawer.

| Badge | Condition |
|---|---|
| `realLocation` | `locationMode == LocationMode.live` |
| `spoofLocation` | `locationMode == LocationMode.spoof` |
| `realCamera` | `effectiveCameraMode == CameraAccessMode.real` |
| `virtualCamera` | `effectiveCameraMode == CameraAccessMode.virtual` |
| `realMicrophone` | `effectiveMicrophoneMode == MicrophoneAccessMode.real` |
| `virtualMicrophone` | `effectiveMicrophoneMode == MicrophoneAccessMode.virtual` |
| `virtualScreenShare` | `effectiveScreenShareMode == ScreenShareMode.virtual` |
| `notifications` | `effectiveNotificationsEnabled` |
| `protectedContent` | `effectiveProtectedContentAllowed == true`, on an Android host |
| `backgroundAudio` | `effectiveBackgroundAudioEnabled` |

Undecided (`ask`), denied (`block`) and `LocationMode.off` SHALL produce
no badge: a badge means "this site has been granted something", never
"this site once asked". The `effective*` getters are read, never the raw
fields, so an archive-tier site (ARCH-006) shows no badge for a grant the
archive fold disables while the stored intent survives underneath, and a site
under Tracking Protection shows no protected-content badge. Protected content
is badged only on Android, the only host that consults the setting, matching
the Permissions row, which shows it only there. Notifications carry no engine
gate: the polyfill answers `granted` whenever the flag is on.

`realMicrophone` SHALL be treated as real device access by the badge's
`_isRealDeviceAccess`, so it renders in the theme's error colour alongside
`realLocation` and `realCamera`. This badge is not decoration: MIC-014 lists
visibility as one of the clauses that make holding the recording capability
defensible, and the drawer is the only surface that shows a grant the user
settled months ago without their opening the site's settings.

There is no `realScreenShare` badge because there is no mode that produces
one (SHARE-001): a display capture is whole-surface, so granting one would
hand the site every other site in the webspace, and the app offers no such
grant on any platform.

#### Scenario: A site with no grants shows nothing

**Given** a site with `locationMode == off`, `cameraMode == ask`, `microphoneMode == ask`, `screenShareMode == ask`, notifications off, `protectedContentAllowed == null` and background audio off
**When** its drawer tile renders
**Then** no permission badge is drawn

#### Scenario: Blocked is not a grant

**Given** a site with `cameraMode == block`, `microphoneMode == block` and `screenShareMode == block`
**When** its drawer tile renders
**Then** no permission badge is drawn

#### Scenario: Every grant is surfaced in a stable order

**Given** a site on Android with `locationMode == live`, `cameraMode == real`, `microphoneMode == real`, `screenShareMode == virtual`, notifications on, `protectedContentAllowed == true` and background audio on
**When** its drawer tile has room for every badge
**Then** the badges read location, camera, microphone, screen sharing, notifications, protected content, background audio in that order

#### Scenario: A notification grant is badged

**Given** a site whose Permissions row lists Notifications as allowed and nothing else
**When** its drawer tile renders
**Then** a notifications badge is drawn in the error colour

#### Scenario: A real microphone reads as a device grant

**Given** a site with `microphoneMode == real`
**When** its drawer tile renders
**Then** the microphone badge is drawn in the error colour
**And** a site with `microphoneMode == virtual` draws its microphone badge muted

#### Scenario: Archive-tier sites show no capture badge

**Given** an archive-tier site whose stored `cameraMode == real`, `microphoneMode == real`, `screenShareMode == virtual`, notifications on, `protectedContentAllowed == true` and background audio on
**When** its drawer tile renders
**Then** no badge is drawn, because the effective values are `block` / `block` / `block` / off / `false` / off
**And** the stored modes are unchanged for when the site leaves the archive

### Requirement: PERMBADGE-002 — Real Device Access Reads Differently From Simulated

A badge for a grant that hands the site a real device or capability
(`realLocation`, `realCamera`, `realMicrophone`, `notifications`,
`protectedContent`) SHALL render with the filled glyph in
`ColorScheme.error`, as the Permissions row draws the same grants; a badge for a grant the app satisfies synthetically
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

### Requirement: PERMBADGE-005 — Every Grant Stays Visible Inside Its Tile

The badge strip SHALL draw every badge the site holds, SHALL never draw
outside the width its tile gives it, and SHALL never squeeze the site's name
to nothing. Badges that do not fit on one row wrap onto another; none is
elided, counted or summarised. In the wide layout the strip gets at most
half of the width beside the favicon, so the name keeps the other half, and
its rows stack beside the name. In the narrow layout it is bounded by the
favicon's width and a second row grows up over the favicon.

Both layouts SHALL have room for every badge the app can grant at once: the
narrowest wide tile (132 across, 60 of it beside the favicon, 80 of content
height) holds the full set in two-badge rows, and a 48-wide favicon holds it
in two rows.

#### Scenario: More grants than one row holds wrap

**Given** a site holding more grants than fit on one row beside its favicon
**When** its drawer tile renders
**Then** the badges wrap onto another row within the tile
**And** every badge is drawn
**And** the name keeps at least half the width beside the favicon

#### Scenario: The full set fits the tightest tiles

**Given** a site on Android holding every grant the app offers
**When** it renders in the narrowest wide tile, or over a 48-wide favicon
**Then** all seven badges are drawn inside the strip's bounds
