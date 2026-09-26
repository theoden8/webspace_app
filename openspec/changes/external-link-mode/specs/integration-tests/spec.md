## MODIFIED Requirements

### Requirement: INTEG-010 — Android white-screen pixel scenarios

`integration_test/white_screen_test.dart` SHALL drive the
in-process-drivable BUG-001 entry paths
([docs/bugs/001-white-screen.md](../../../../../docs/bugs/001-white-screen.md))
on an Android emulator/device and assert on the **composited window
pixels** over the webview slot, sampled by
`SurfaceDiagPlugin.sampleWindowRegion` (window-level `PixelCopy`).
This is the only capture plane that shows what the user sees:
Flutter's `convertFlutterSurfaceToImage` misses hybrid-composition
platform views, and a JS probe reports the renderer plane, which is
healthy in every confirmed BUG-001 instance. Pages come from an
in-process loopback HTTP server so a network failure can never
masquerade as a white screen, and each content page is a solid color
Flutter never draws so a matching dominant color proves the sample
came from the webview.

The suite SHALL cover at least: fresh first activation (BUG-001 gap
#7), loaded-site switch (`_setCurrentIndex` reuse), the reload funnel
(`PAUSE-021`), memory pressure against the visible site
(`PAUSE-019`), fresh activation with other sites live
(`PAUSE-017`), the return from a pushed opaque route (`PAUSE-024`),
and the nested `InAppWebViewScreen` — both its own fresh surface and
the return to the main page behind it (`PAUSE-026`). Warm start,
activity recreation, and bfcache back navigation need real activity
lifecycle transitions an in-process test cannot produce; those belong
to the adb-driven lifecycle tier (INTEG-011).

At least one scenario per commit-side repaint (`PAUSE-021`,
`PAUSE-025`) SHALL be driven by a page that **withholds its first byte
longer than the nudge's tick budget** (~0.6s). A page that commits
instantly is repainted by the issue-time nudge whether or not the
settled-side re-nudge exists, so an all-instant suite cannot fail on
the ordering defect that every BUG-001 recurrence since Attempt 8 has
actually been — it asserts only that the app renders at all. The
delay SHALL come from the in-process server holding the response, not
from a slow network, so the scenario stays deterministic.

The nested-screen scenario SHALL reach the nested route by submitting a
**cross-domain address in the seeded site's URL bar** (a script cannot
open it: every site blocks gesture-less cross-domain navigations,
NESTED-004), and the cross-domain target SHALL be the
same in-process server reached under a second loopback address
(`127.0.0.2` alongside `127.0.0.1`, hence a server bound to
`anyIPv4`). Two hosts on one server keep the navigation genuinely
cross-domain — `getBaseDomain` compares IP literals — while keeping a
network failure impossible, and typed input keeps the scenario off any
synthetic touch reaching the platform view.

#### Scenario: A late-committing document is repainted promptly

- **Given** a seeded site whose page withholds its first byte for
  longer than the repaint nudge's tick budget
- **When** the suite activates it, so the surface attaches and every
  issue-time nudge drains before the document commits
- **Then** the composited webview region shows the page's color within
  a bounded settle window, which only the settled-side re-nudge
  (`PAUSE-025`) can produce
- **And** the deadline is tight on purpose: a blank that clears much
  later, on some unrelated relayout, is still the bug

#### Scenario: White control page proves the detector is not vacuous

- **Given** a seeded site whose page is genuinely all-white
- **When** the suite activates it and samples the webview rect
- **Then** `SurfaceDiagNative.classify` reports `uniformBlank`
- **And** a sampler regression that stops seeing webview pixels
  therefore fails this scenario instead of silently passing the rest

#### Scenario: A blank window fails the run with the sample as diagnostic

- **Given** any covered entry path leaves the composited webview
  region uniform white/black after its settle window
- **When** the polling assertion times out
- **Then** the test fails and prints the last `WindowRegionSample`
  (status, dominant color, uniform fraction) plus the in-memory
  `LogService` tail, which is safe to surface because the test data
  is synthetic (loopback URLs, seeded names)

#### Scenario: Runs inside build-android on every push/PR

- **Given** the `build-android` job has built the APKs and its
  emulator prerequisites (KVM, Android SDK, API 34 google_apis x86_64
  `pixel_5` AVD snapshot cache) are ungated
- **When** the `Run emulator integration scenarios` step runs
  `fvm flutter test integration_test/white_screen_test.dart -d <device> --flavor fdebug`
  inside the booted emulator with a 25-minute wall-clock cap
- **Then** the suite executes on every push to master, every PR, and
  every manual dispatch, and a failure fails `build-android`
- **And** the screenshot generation step after it remains gated on
  `workflow_dispatch`, booting the emulator a second time on dispatch
  runs

#### Scenario: Desktop loops skip the Android-only suite

- **Given** the Linux and macOS integration loops iterate
  `integration_test/*_test.dart`
- **When** they reach `white_screen_test.dart`
- **Then** both skip it by basename (like `screenshot_test.dart`),
  because the `PixelCopy` channel exists only on Android and the
  `skip: !Platform.isAndroid` guard would still cost a desktop debug
  build per run
