## MODIFIED Requirements

### Requirement: BGAUDIO-008 — Only the Playing Frame Speaks for the Site

The shim is injected with `forMainFrameOnly: false`, so every frame of the
site runs a copy against the single `wsMediaSession` handler. Reports SHALL
therefore be frame-scoped:

- The shim SHALL mint one opaque token per frame and send it as `frame` in
  every report.
- A frame that has never held an `<audio>`/`<video>` element (its own or a
  detached one) SHALL NOT report at all. An ad / analytics / comments iframe
  has nothing to say about playback.
- `MediaSessionService` SHALL record the reporting frame on every
  `playing: true` and SHALL accept `playing: false` only from that same
  frame of that same site.
- Ownership moves with playback, but not to any frame that asks for it. The
  frame token is minted by the shim, which runs in an ad iframe too, so "who
  reported last" is otherwise all it takes to retitle what the user is
  listening to and inherit its transport controls. A **subframe** report of
  `playing: true` SHALL therefore take ownership only when no main frame holds
  it. A main-frame report takes ownership as before. Whether a report came from
  the top document SHALL be read from the `wsMediaSession` handler's frame data
  (computed by the plugin's bridge preamble), never from the page's payload.

Without this, a site whose player sits in the main frame is silenced by its
own subframes: the ad iframe reports `playing: false` for the same `siteId`
within one debounce of the notification going up, flipping it to a paused,
`setOngoing(false)` — dismissible — state while audio is still playing, and
the main frame's report deduplication keeps it from correcting the record.

The transport controls remain main-frame-only: `evaluateJavascript` targets
the main frame, so a player inside a subframe raises the notification but its
play/pause buttons do not reach the element. Accepted degradation.

#### Scenario: An ad iframe cannot pause the notification

**Given** a background-audio site is playing in its main frame and the
notification is up
**When** a media-less iframe of the same site reports
**Then** nothing is sent — the frame is silent because it never held media
(regression test: `test/browser/media_session_frames.test.js`)
**And** even if it did report `playing: false`, the frame guard would drop it
(regression test: `test/media_session_service_test.dart`)

#### Scenario: An ad iframe cannot retitle what is playing

**Given** a background-audio site is playing in its main frame and the
notification is up
**When** a subframe of the same site reports `playing: true` with its own
title and artwork
**Then** the notification still shows the main frame's track
(regression test: `test/media_session_service_test.dart`)

#### Scenario: Playback moving between frames transfers ownership

**Given** a background-audio site whose top document never plays anything
**When** its player iframe reports `playing: true`
**Then** the subframe becomes the owner and its later `playing: false` is
honored
**And** a main-frame report takes ownership from any frame, as before
