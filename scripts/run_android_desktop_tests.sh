#!/usr/bin/env bash
# Android desktop tier (NAV-019, INTEG-018): integration_test/android_desktop_test.dart
# on an Android desktop emulator, where the app opens in a window with a
# header and a keyboard and a mouse drive it. WS_DESKTOP_TIER tells the test
# it is on that tier; without it the file skips, as it does on the phone and
# TV emulators and the desktop jobs.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
adb_() { adb -s "$device_id" "$@"; }

# The image boots to its lock screen, which holds the focus: no key the test
# types would reach the app.
adb_ shell input keyevent KEYCODE_WAKEUP
adb_ shell wm dismiss-keyguard || true
adb_ shell input keyevent 82 || true
adb_ shell svc power stayon true || true

# `flutter test` starts the app as adb does, full screen. Once its task
# exists it is moved into a desktop window, by WM Shell's command under each
# name it has had; the test waits for the window's header.
to_desktop_window() {
  local tasks task out
  for _ in $(seq 1 240); do
    tasks=$(adb_ shell dumpsys activity activities 2>/dev/null || true)
    task=$(sed -n "s/.*Task{[0-9a-f]* #\([0-9]*\) .*A=[0-9]*:${ANDROID_TIER_PKG} .*/\1/p" <<<"$tasks")
    task=${task%%$'\n'*}
    if [ -n "$task" ]; then
      for command in moveToDesktop moveTaskToDesk; do
        out=$(adb_ shell dumpsys activity service SystemUIService WMShell \
          desktopmode "$command" "$task" 2>&1 || true)
        echo "desktop window: $command $task: ${out:0:300}"
      done
      return 0
    fi
    sleep 1
  done
  echo "desktop window: no task for $ANDROID_TIER_PKG" >&2
}
to_desktop_window &

run_tier integration_test/android_desktop_test.dart 20 --define WS_DESKTOP_TIER=true
