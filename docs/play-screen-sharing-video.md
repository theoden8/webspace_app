# Screen-sharing review video

The `Record Android screen sharing` CI job records an unmodified release app
on an Android 15 emulator. It uses the existing `fdroid` flavor's CI signing,
not the Play signing key. The app entrypoint, permission dialogs and Android
MediaProjection service are the production implementations.

Before recording, the runner enables **App Settings → Appearance → Legacy
design** through the visible settings UI and verifies the switch is on. The
walkthrough starts in the older webspace list and opens Add Site from its
navigation drawer. The settings screenshot is included as evidence.

Run only this job and its small planner by putting `[ci-only: capture]` in the
PR head commit message. Once the workflow is on master, a manual **Build and
Test** run with `capture_only: true` does the same. No other build, test or
screenshot tier runs. The capture job is off in ordinary runs.

Download the `screen-sharing-review-video` artifact from the Actions run:

- `screen-sharing.mp4`: H.264 video for review and upload to an unlisted video host.
- `screen-sharing.webm`: the original, unedited emulator recording.
- Numbered PNG/XML snapshots: launch, demo page, both consent prompts, live
  preview, foreground notification and stopped state.
- `events.json`, `projection-*.txt`, `services-active.txt`, `build.json`:
  observed moving video frames, actual Android service ownership, teardown,
  source commit and APK hash. `result.json` exists only after a complete pass.
- `latest-ui.xml` and `logcat.txt`: diagnostics, including on a failed attempt.

The runner serves `tool/screen_share_demo/index.html` on localhost through
`adb reverse`. This is a real website calling `getDisplayMedia`, not a mocked
stream or permission grant. The recording includes adding the site, tapping
Start sharing, WebSpace's disclosure, Android's screen-capture consent,
the live preview, and Stop sharing in the foreground notification. Screen
sharing remains at its default Ask mode; no projection permission is pregranted.
Notification permission is granted during emulator setup so the stop control
is visible. The moving bar makes a frozen or black stream detectable.

Recording uses `adb emu screenrecord`, which captures on the emulator host and
does not start a second Android MediaProjection session. The artifact is kept
for 30 days. Watch the MP4 before submitting it to Play; CI checks the observed
flow and moving frames, not Google's approval decision.

For a local run on a disposable Android emulator, build
`fvm flutter build apk --release --flavor fdroid --target-platform android-x64`,
then run `python3 scripts/capture_screen_share_video.py`. It requires `adb`,
`ffmpeg` and `ffprobe`, clears only the emulator's WebSpace data, and saves
everything under `build/screen-share-video/`.
