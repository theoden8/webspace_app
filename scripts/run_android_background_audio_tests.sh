#!/usr/bin/env bash
# Android-emulator background-audio tier (BGAUDIO-002 / BGAUDIO-005): run the
# background-audio integration tests against a real Android WebView, where
# `pauseTimers()` is actually implemented. That makes provable here two things
# the Linux/WPE + macOS runs and the pure-Dart engine tests cannot:
#   - the exempt direction end-to-end (a background-audio site keeps ticking
#     across an injected background window),
#   - the negative control (a plain site's JS timers genuinely freeze), and
#   - BGAUDIO-006, the media notification: the foreground service and its
#     MediaStyle notification only exist on Android, so this is the only tier
#     that can assert the user-visible half of the feature,
#   - BGAUDIO-009, the media stop: a site WITHOUT the toggle must go quiet when
#     it loses the screen, which needs a real media pipeline to observe.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"

# POST_NOTIFICATIONS is pre-granted so the notification tier measures the
# feature, not the permission dialog: on API 33+ a denied grant leaves the
# foreground service running with nothing on screen, which is exactly the
# failure the test is built to catch — but as a *product* bug, not a harness
# one.
grant_when_installed POST_NOTIFICATIONS

status=0
for t in \
  integration_test/background_audio_lifecycle_test.dart \
  integration_test/background_audio_freeze_test.dart \
  integration_test/background_audio_media_notification_test.dart \
  integration_test/background_audio_media_stop_test.dart; do
  echo "::group::$t"
  rc=0
  tier_test "$t" 12 || rc=$?
  if [ $rc -ne 0 ]; then
    status=$rc
    [ $rc -eq 124 ] && echo "::error::$t killed after 12m wall-clock cap"
  fi
  echo "::endgroup::"
done
exit $status
