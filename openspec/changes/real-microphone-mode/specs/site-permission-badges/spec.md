# Site Permission Badges — real microphone delta

Based on the `web-screen-sharing` version of PERMBADGE-001 (implemented, not
yet archived), so the `virtualScreenShare` row it added is carried forward
here rather than reverted.

## MODIFIED Requirements

### Requirement: PERMBADGE-001 — Badge Set Derives From Effective Per-Site State

`sitePermissionBadges(WebViewModel)`
([lib/widgets/site_permission_badges.dart](../../../lib/widgets/site_permission_badges.dart))
SHALL return exactly the grants the site currently holds, in the fixed
order location, camera, microphone, screen sharing, background audio:

| Badge | Condition |
|---|---|
| `realLocation` | `locationMode == LocationMode.live` |
| `spoofLocation` | `locationMode == LocationMode.spoof` |
| `realCamera` | `effectiveCameraMode == CameraAccessMode.real` |
| `virtualCamera` | `effectiveCameraMode == CameraAccessMode.virtual` |
| `realMicrophone` | `effectiveMicrophoneMode == MicrophoneAccessMode.real` |
| `virtualMicrophone` | `effectiveMicrophoneMode == MicrophoneAccessMode.virtual` |
| `virtualScreenShare` | `effectiveScreenShareMode == ScreenShareMode.virtual` |
| `backgroundAudio` | `effectiveBackgroundAudioEnabled` |

Undecided (`ask`), denied (`block`) and `LocationMode.off` SHALL produce
no badge: a badge means "this site has been granted something", never
"this site once asked". The `effective*` getters are read, never the raw
fields, so an archive-tier site (ARCH-006) shows no badge for a grant the
archive fold disables while the stored intent survives underneath.

`realMicrophone` SHALL be treated as real device access by
`opensRealDevice`, so it renders in the theme's error colour alongside
`realLocation` and `realCamera`. This badge is not decoration: MIC-014 lists
visibility as one of the clauses that make holding the recording capability
defensible, and the drawer is the only surface that shows a grant the user
settled months ago without their opening the site's settings.

There is no `realScreenShare` badge because there is no mode that produces
one (SHARE-001): a display capture is whole-surface, so granting one would
hand the site every other site in the webspace, and the app offers no such
grant on any platform.

#### Scenario: A site with no grants shows nothing

**Given** a site with `locationMode == off`, `cameraMode == ask`, `microphoneMode == ask`, `screenShareMode == ask` and background audio off
**When** its drawer tile renders
**Then** no permission badge is drawn

#### Scenario: Blocked is not a grant

**Given** a site with `cameraMode == block`, `microphoneMode == block` and `screenShareMode == block`
**When** its drawer tile renders
**Then** no permission badge is drawn

#### Scenario: Every grant is surfaced in a stable order

**Given** a site with `locationMode == live`, `cameraMode == real`, `microphoneMode == real`, `screenShareMode == virtual` and background audio on
**When** its drawer tile renders
**Then** the badges read location, camera, microphone, screen sharing, background audio in that order

#### Scenario: A real microphone reads as a device grant

**Given** a site with `microphoneMode == real`
**When** its drawer tile renders
**Then** the microphone badge is drawn in the error colour
**And** a site with `microphoneMode == virtual` draws its microphone badge muted

#### Scenario: Archive-tier sites show no capture badge

**Given** an archive-tier site whose stored `cameraMode == real`, `microphoneMode == real`, `screenShareMode == virtual` and background audio on
**When** its drawer tile renders
**Then** no badge is drawn, because the effective modes are `block` / `block` / `block` / off
**And** the stored modes are unchanged for when the site leaves the archive
