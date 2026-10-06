# BUG-023 — A system bar covers controls in full screen

Status: open

**Spec:** [fullscreen-mode](../../openspec/specs/fullscreen-mode/spec.md) FS-006,
FS-011
**Tests:** [test/fullscreen_system_bars_test.dart](../../test/fullscreen_system_bars_test.dart)
(the mode the shipped app asks for, and the kept strip moving above a revealed
bar), [test/js/fullscreen_system_ui_funnel.test.js](../../test/js/fullscreen_system_ui_funnel.test.js)
(no path names an immersive mode itself)

## Symptom

In full screen on Android, a system bar sits on top of something the user has
to tap, and the tap goes to the bar or nowhere:

- github #385: the site's own menu at the top edge and its buttons at the
  bottom edge, behind status and navigation bars that full screen had not
  hidden (Android 15).
- github #672: the tab strip kept in full screen (FS-007), behind the
  navigation bar the user swiped in to reach back or home.

## Root mechanism / invariant

Flutter can only lay out around a bar it is told about, through the window
insets. Each instance is a bar on screen whose insets the app's layout does
not see, or does not use. The invariant: **in full screen, every system bar
on screen is one whose insets reach the layout, or nothing the user needs is
under it.**

Android's sticky immersive mode breaks that by design: a swiped-in bar is a
transient overlay, and Android keeps reporting it hidden to the app, so no
insets arrive and the system UI visibility listener does not fire.

## Fix attempts

1. **2026-05-29 — PR #386.** Kept the body's top and bottom `SafeArea` active
   in full screen. *Why*: `immersiveSticky` did not always hide the bars on
   Android 15 with edge-to-edge enforced; a bar that stays is a real one with
   insets, and the inset is ~0 once the bars are hidden. *Why partial*: it
   covered bars that persist, and only the body. A bar the user swipes in
   under sticky immersive reports no insets, so no `SafeArea` can move
   anything out from under it; the tab strip kept in full screen sits exactly
   there.

2. **2026-10-06 — github #672.** Full screen asks for `immersive` instead of
   `immersiveSticky` whenever it shows the app's own controls (the kept tab
   strip, or the tab-bar button and the strip it reveals), and hides revealed
   bars again 3 seconds after the platform reports them
   (`SystemChrome.setSystemUIChangeCallback`). Every full-screen mode request
   goes through `_fullscreenSystemUiMode`, gated by
   `test/js/fullscreen_system_ui_funnel.test.js`. *Why*: under `immersive` a
   revealed bar is real: its insets arrive and the strip's own bottom
   `SafeArea` lifts it above the bar. *Why partial*: it keeps sticky for a
   full screen without app controls, where web content at the bottom edge is
   still covered by a swiped-in bar until it times out, which is how full
   screen behaves in most apps. Verified on the policy and layout in widget
   tests, not on a device: no emulator tier swipes a system bar in.

## Known open gaps

- Web content at the screen edges in a full screen without app controls is
  covered by a revealed bar for as long as the bar stays (by choice, see
  attempt 2).
- No emulator scenario reveals a bar with a swipe and checks where the strip
  lands; the platform half (the reveal producing insets and the callback) is
  covered only by the engine's documented behaviour.
