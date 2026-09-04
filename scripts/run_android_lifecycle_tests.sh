#!/usr/bin/env bash
# Adb-driven white-screen lifecycle tier (BUG-001 / INTEG-011): the entry
# paths that need real activity transitions — warm start (PAUSE-020),
# back navigation into a bfcached entry (PAUSE-018), activity recreation —
# driven from outside the app process, with the symptom read from the
# composited frame (screencap) by classify_window_pixels.py. Pages are
# served from the host (10.0.2.2 from the emulator) so a network failure
# cannot masquerade as a white screen, and each page is a solid color
# Flutter never draws so a matching dominant color proves the webview
# composited.
#
# The same driver covers the warm home-shortcut taps (HS-002 / HS-006,
# INTEG-013): a tap on a pinned tile while the app runs arrives as
# onNewIntent, which no in-process test can produce.
#
# The in-process suite (run_android_integration_tests.sh) leaves an APK
# whose Dart entrypoint is the *test* main, so this tier always rebuilds
# and installs the default-entrypoint debug APK before driving it.
set -euo pipefail

# Hard wall-clock cap, like the sibling script: a webview mount can
# deadlock below every polling deadline.
if [ "${WS_LIFECYCLE_WRAPPED:-}" != "1" ]; then
  exec env WS_LIFECYCLE_WRAPPED=1 timeout -k 30s 25m "$0" "$@"
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi
export ANDROID_SERIAL="$device_id"

pkg="org.codeberg.theoden8.webspace"
component="$pkg/.MainActivity"
artifacts="$root/build/white_screen_adb"
classify="$root/scripts/classify_window_pixels.py"
dark=123524
magenta=8c1d5a
blue=1d3f8c
mkdir -p "$artifacts"

# System error dialogs: a launcher ANR on the loaded CI host parks a
# scrimmed, non-cancelable dialog over everything and corrupts every
# pixel sample (two runs failed on exactly this, uniform=0.578 both
# times). hide_error_dialogs only gates future dialogs — the CI step
# also sets it before the in-process suite so the whole emulator
# session is covered — and the only reliable dismissal of one already
# parked is force-stopping the ANR'd process; the launcher restarts on
# the next HOME press.
adb shell settings put global hide_error_dialogs 1
home_pkg="$(adb shell cmd package resolve-activity --brief \
  -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
  | tail -1 | cut -d/ -f1 | tr -d '[:space:]')"
if [ -n "$home_pkg" ] && [ "$home_pkg" != "$pkg" ]; then
  adb shell am force-stop "$home_pkg" 2>/dev/null || true
fi
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true

www="$(mktemp -d)"
server_log="$www/server.log"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  adb shell settings put global always_finish_activities 0 >/dev/null 2>&1 || true
  adb shell settings put global hide_error_dialogs 0 >/dev/null 2>&1 || true
  adb shell svc power stayon false >/dev/null 2>&1 || true
}
trap cleanup EXIT

page() { # $1 = css background, $2 = optional link target (full-page anchor)
  printf '<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>html,body{margin:0;height:100%%;background:%s;}a{position:fixed;inset:0;}</style></head><body>%s</body></html>' \
    "$1" "${2:+<a href=\"$2\"></a>}"
}
page '#123524' 'magenta.html' > "$www/dark.html"
page '#8c1d5a' > "$www/magenta.html"
page '#ffffff' > "$www/white.html"
page '#1d3f8c' > "$www/blue.html"

# Same dark fill, plus a JS Notification on every load: a forced
# background refresh reloads the page, so a new OS notification is the
# outside-observable proof the whole NOTIF-005-A pipeline ran (worker ->
# engine -> site reload -> polyfill -> flutter_local_notifications).
# The beacon request is the second, independent signal: it says the page
# was re-fetched even when no notification follows, which is what splits
# "the worker never reached the engine" from "the reload ran but the
# notification pipeline dropped it" in the failure message.
cat > "$www/notif.html" <<'EOF'
<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>html,body{margin:0;height:100%;background:#123524;}</style></head><body><script>
(function () {
  var stamp = String(Date.now()) + '-' + Math.floor(Math.random() * 1e6);
  try { fetch('/beacon?load=' + stamp, {cache: 'no-store'}); } catch (e) {}
  function fire() {
    try { new Notification('ws-diag-bg', {body: stamp}); } catch (e) {}
  }
  if (typeof Notification === 'undefined') return;
  if (Notification.permission === 'granted') { fire(); return; }
  try {
    Notification.requestPermission().then(function (p) {
      if (p === 'granted') fire();
    });
  } catch (e) {}
})();
</script></body></html>
EOF

python3 - "$www" > "$server_log" 2>&1 <<'EOF' &
import http.server, os, sys
os.chdir(sys.argv[1])
srv = http.server.ThreadingHTTPServer(('0.0.0.0', 0),
                                      http.server.SimpleHTTPRequestHandler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
EOF
server_pid=$!
port=""
for _ in $(seq 1 50); do
  port="$(head -1 "$server_log" 2>/dev/null || true)"
  [ -n "$port" ] && break
  sleep 0.2
done
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
  echo "ERROR: page server failed to start" >&2
  cat "$server_log" >&2
  exit 1
fi
base="http://10.0.2.2:$port"
echo "Serving diag pages from $base (host pid $server_pid)"

# Per-run unique siteIds: no keyed state (cookies, containers, nav-state)
# can bleed across runs, and the harness knows the id to activate. A plain
# cold start lands on the webspace picker with no site selected, so every
# seeded launch also passes the production pinned-shortcut `siteId` extra,
# which StartupRestoreEngine.resolveLaunch matches directly — the same
# path a launcher shortcut tap takes.
run_tag="adb-$(date +%s)"
dark_site_id="ws-$run_tag-dark"
white_site_id="ws-$run_tag-white"
notif_site_id="ws-$run_tag-notif"
blue_site_id="ws-$run_tag-blue"

site_json() { # $1 = page basename, $2 = siteId, $3 = extra site fields (optional)
  printf '{"name":"Diag","url":"%s/%s","siteId":"%s"%s}' \
    "$base" "$1" "$2" "${3:-}"
}

seed_b64() { # $1 = page basename, $2 = siteId, $3 = extra site fields (optional)
  printf '{"sites":[%s]}' "$(site_json "$1" "$2" "${3:-}")" | base64 | tr -d '\n'
}

seed_pair_b64() { # $1/$2 = first page + siteId, $3/$4 = second page + siteId
  printf '{"sites":[%s,%s]}' \
    "$(site_json "$1" "$2")" "$(site_json "$3" "$4")" | base64 | tr -d '\n'
}

echo "== Building default-entrypoint fdebug APK"
fvm flutter build apk --debug --flavor fdebug -t lib/main.dart
apk="build/app/outputs/flutter-apk/app-fdebug-debug.apk"
if [ ! -f "$apk" ]; then
  echo "ERROR: $apk not produced" >&2
  exit 1
fi
adb install -r "$apk"
# Pristine state: the in-process suite ran this package earlier in the
# same emulator session and may have left containers/secure storage.
# pm clear also resets runtime permission grants, so the notification
# grant must come after it (pre-granted = no permission dialog steals
# the screen when the notif scenario's page requests permission).
adb shell pm clear "$pkg" >/dev/null
adb shell pm grant "$pkg" android.permission.POST_NOTIFICATIONS

sample="$www/frame.raw"
wait_for_pixels() { # $1 = slug, $2 = deadline secs, rest = classifier expectation
  local slug="$1" deadline="$2" start now out
  shift 2
  start=$(date +%s)
  while :; do
    adb exec-out screencap > "$sample" 2>/dev/null || true
    if out="$(python3 "$classify" --file "$sample" "$@")"; then
      echo "  $slug: $out"
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$deadline" ]; then
      echo "FAIL: $slug did not reach the expected pixels within ${deadline}s" >&2
      echo "  last classification: $out" >&2
      adb exec-out screencap -p > "$artifacts/fail-$slug.png" 2>/dev/null || true
      adb logcat -d -t 500 > "$artifacts/fail-$slug.logcat.txt" 2>/dev/null || true
      printf '%s\n' "$out" > "$artifacts/fail-$slug.classify.json" || true
      exit 1
    fi
    sleep 1
  done
}

adb shell input keyevent KEYCODE_WAKEUP
adb shell input keyevent 82
adb shell svc power stayon true
adb shell settings put global always_finish_activities 0

echo "== Scenario A: pinned-shortcut cold start onto the seeded dark site"
adb shell am force-stop "$pkg"
adb shell am start -W -n "$component" \
  --es ws_diag_seed "$(seed_b64 dark.html "$dark_site_id")" \
  --es siteId "$dark_site_id"
wait_for_pixels cold-start-dark 180 --expect-dominant "$dark"

echo "== Scenario B: warm start repaints the re-attached surface (PAUSE-020)"
adb shell input keyevent 3
sleep 5
adb shell am start -W -n "$component"
wait_for_pixels warm-start-dark 90 --expect-dominant "$dark"

# Scenario B2 asks a question the rest of the suite structurally cannot: does
# ANYTHING below Dart repaint the surface when the window comes back?
#
# Every warm-start repaint the app has keys on a Dart-side signal — the
# `_onResumed` tail nudge (PAUSE-015) and the `didChangeMetrics` re-nudge
# (PAUSE-020). BUG-001 gap #5 is that `didChangeMetrics` is a *proxy* for the
# SurfaceView reattach, not the reattach: Flutter can dedupe identical window
# metrics and the callback tracks the main FlutterView. On a device where it
# does not fire, Attempt 8 is a no-op — and Scenario B above cannot tell that
# device from a healthy one, because on the emulator the proxy always fires.
#
# Suppressing both triggers by name simulates that device exactly. What repaints
# the surface afterwards, if anything, is whatever the native layer does on its
# own. Modeled as `Fix="proxy"` vs `Fix="attach"` in formal/warmstart.tla.
#
# EXPECTED RED against a fork with no native attach/visibility repaint hook.
# That red IS the reproduction: evidence that the surface depends on a Dart
# proxy nobody has confirmed fires. It turns green when the fork gains the hook
# (upstream starship-s 643cf23 + 1a8ed58 add exactly that), at which point this
# becomes its regression guard.
#
# OPT-IN, because a scenario that is red by design would drown the signal from
# every other scenario in this tier. Set WS_RUN_NATIVE_REPAINT_PROBE=1 to run
# it — the PR that bumps the fork pin turns it on for good.
if [ "${WS_RUN_NATIVE_REPAINT_PROBE:-0}" != "1" ]; then
  echo "== Scenario B2: SKIPPED (set WS_RUN_NATIVE_REPAINT_PROBE=1 to run)"
else
  echo "== Scenario B2: warm start with the Dart resume nudges suppressed"
  echo "   (BUG-001 gap #5: does the native layer repaint on its own?)"
  adb shell am force-stop "$pkg"
  adb shell am start -W -n "$component" \
    --es ws_diag_seed "$(seed_b64 dark.html "$dark_site_id")" \
    --es ws_diag_suppress_repaint "resume,metrics-resume" \
    --es siteId "$dark_site_id"
  wait_for_pixels b2-cold-start-dark 180 --expect-dominant "$dark"
  adb shell input keyevent 3
  sleep 5
  # No seed extra on the return: the suppression is already armed in-process,
  # and reseeding would restart the app rather than warm-start it.
  adb shell am start -W -n "$component"
  wait_for_pixels b2-warm-start-native-repaint 90 --expect-dominant "$dark"
fi

echo "== Scenario C: back into a bfcached entry repaints (PAUSE-018)"
size="$(adb shell wm size | sed -n 's/.*: *\([0-9]*\)x\([0-9]*\).*/\1 \2/p' | head -1)"
w="${size% *}"
h="${size#* }"
adb shell input tap "$((w / 2))" "$((h / 2))"
wait_for_pixels forward-nav-magenta 90 --expect-dominant "$magenta"
adb shell input keyevent 4
wait_for_pixels back-nav-dark 90 --expect-dominant "$dark"

echo "== Scenario D: activity recreation ends painted"
adb shell settings put global always_finish_activities 1
adb shell input keyevent 3
sleep 5
adb shell am start -W -n "$component" \
  --es ws_diag_seed "$(seed_b64 dark.html "$dark_site_id")" \
  --es siteId "$dark_site_id"
wait_for_pixels recreation-dark 180 --expect-dominant "$dark"
adb shell settings put global always_finish_activities 0

echo "== Scenario E: white control page must classify as the white blank"
adb shell am force-stop "$pkg"
adb shell am start -W -n "$component" \
  --es ws_diag_seed "$(seed_b64 white.html "$white_site_id")" \
  --es siteId "$white_site_id"
wait_for_pixels white-control 180 --expect-blank-white

# ---- Background refresh (NOTIF-005-A / INTEG-012) ----

# Notification *identities*, not a record count. A record count cannot see a
# repost: Android collapses on the (tag, id) pair, so a second post with the
# same pair updates the existing record and the count never moves — while the
# same record does transiently appear in more than one dumpsys section
# (enqueued + posted), which made a count-based assertion pass or fail on
# whether the poll landed inside that window. `key` is `user|pkg|id|tag|uid`
# (StatusBarNotification.getKey), stable across versions and printed in every
# section, so a set difference over keys is the honest "a new notification was
# posted" signal.
notif_keys() {
  adb shell dumpsys notification 2>/dev/null \
    | grep -o "[0-9]*|$pkg|[^|]*|[^|]*|[0-9]*" | sort -u || true
}

notif_records() {
  adb shell dumpsys notification 2>/dev/null \
    | grep -c "NotificationRecord.*$pkg" || true
}

# Each notif.html load fires one /beacon request at the host server.
beacon_hits() {
  grep -c 'GET /beacon' "$server_log" || true
}

# The worker only dispatches `onBackgroundRefresh` when the Flutter engine is
# reachable, so an OS eviction of the backgrounded process looks exactly like a
# broken dispatch leg from the outside. The pid separates them.
app_pid() {
  adb shell pidof "$pkg" 2>/dev/null | tr -d '\r\n' || true
}

dump_bg_diagnostics() { # $1 = slug
  adb shell dumpsys jobscheduler 2>/dev/null | grep -B2 -A12 "$pkg" \
    > "$artifacts/fail-$1.jobscheduler.txt" || true
  adb shell dumpsys notification 2>/dev/null \
    > "$artifacts/fail-$1.notifications.txt" || true
  adb logcat -d -t 500 > "$artifacts/fail-$1.logcat.txt" 2>/dev/null || true
}

echo "== Scenario F: forced periodic refresh reloads the notif site in background"
adb shell am force-stop "$pkg"
adb shell am start -W -n "$component" \
  --es ws_diag_seed "$(seed_b64 notif.html "$notif_site_id" ',"notificationsEnabled":true')" \
  --es siteId "$notif_site_id"
wait_for_pixels notif-cold-start 180 --expect-dominant "$dark"

# The foreground load must itself post one notification first: pins the
# polyfill -> flutter_local_notifications pipeline before any background
# step, and makes the baseline deterministic (the foreground post can
# land a beat after the pixels settle).
deadline=$(( $(date +%s) + 60 ))
while :; do
  baseline_keys="$(notif_keys)"
  [ -n "$baseline_keys" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL: foreground load posted no notification within 60s" >&2
    echo "  notification records for $pkg: $(notif_records) (0 keys parsed)" >&2
    dump_bg_diagnostics notif-foreground-post
    exit 1
  fi
  sleep 2
done
echo "  notification identities after foreground load: $(printf '%s\n' "$baseline_keys" | wc -l | tr -d ' ')"
baseline_beacons="$(beacon_hits)"
adb shell input keyevent 3
sleep 3
baseline_pid="$(app_pid)"
echo "  app pid while backgrounded: ${baseline_pid:-none}"

# NOTIF-005-A schedules unique periodic work (webspace-notification-refresh)
# whenever a notification site exists; WorkManager backs it with a
# JobScheduler job. No job = the scheduling contract itself broke.
job_ids="$(adb shell dumpsys jobscheduler 2>/dev/null \
  | grep "$pkg/androidx.work" \
  | sed -n 's/.*#u[0-9a]*\/\([0-9]\{1,\}\):.*/\1/p' | sort -u)"
if [ -z "$job_ids" ]; then
  echo "FAIL: no WorkManager job scheduled for $pkg (NOTIF-005-A)" >&2
  dump_bg_diagnostics no-workmanager-job
  exit 1
fi
echo "  WorkManager job(s) scheduled: $(echo "$job_ids" | tr '\n' ' ')"

# The job exists, but it cannot be driven with `cmd jobscheduler run -f`:
# that only bypasses JobScheduler's constraints, while WorkManager still
# refuses a periodic WorkSpec whose next run time has not arrived ("executed
# before schedule") and reschedules instead, so nothing reaches the worker.
# Which of those two cases the forced job landed in depended on whether the
# periodic work's first slot had already been spent, i.e. on a race. The
# debug-build receiver enqueues a one-shot of the same worker, which runs the
# leg this scenario is about; the schedule itself is asserted above.
#
# Both legs log under one tag. Read it filtered and counted rather than
# sliced by timestamp: `adb logcat -t '<time>'` cannot carry a space through
# adb's argument joining, and clearing the buffer would cost every later
# scenario its history.
bg_log() { adb logcat -d -s WebspaceBgRefresh:I 2>/dev/null | tr -d '\r' || true; }
bg_log_hits() { bg_log | grep -c "$1" || true; }

triggers_before="$(bg_log_hits 'debug trigger: enqueueing')"
worker_runs_before="$(bg_log_hits 'NotificationRefreshWorker fired')"
echo "  triggering a one-shot refresh via the debug receiver"
adb shell am broadcast -n "$pkg/.NotificationRefreshDebugReceiver" >/dev/null

# `am broadcast` reports the same result whether or not a receiver matched,
# so confirm delivery instead of spending the 90s notification deadline on a
# release APK that never declared the receiver.
deadline=$(( $(date +%s) + 20 ))
while [ "$(bg_log_hits 'debug trigger: enqueueing')" -le "$triggers_before" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL: the debug refresh receiver never fired — is the installed APK" \
         "a debug build (src/debug declares the receiver)?" >&2
    dump_bg_diagnostics no-debug-receiver
    exit 1
  fi
  sleep 1
done

deadline=$(( $(date +%s) + 90 ))
while :; do
  fresh="$(comm -13 <(printf '%s\n' "$baseline_keys") <(notif_keys))"
  if [ -n "$fresh" ]; then
    echo "  background refresh posted a notification: $(printf '%s\n' "$fresh" | head -1)"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    now_beacons="$(beacon_hits)"
    now_pid="$(app_pid)"
    # "the worker never ran" and "the worker ran but Dart never reloaded" are
    # the same silence from outside, and reading the second for the first is
    # what made the last failure unreadable. The worker's own log line splits
    # them.
    worker_runs_now="$(bg_log_hits 'NotificationRefreshWorker fired')"
    echo "FAIL: no new notification within 90s of the refresh trigger" >&2
    echo "  notification identities unchanged (page loads: $baseline_beacons -> $now_beacons)" >&2
    if [ "$now_beacons" -gt "$baseline_beacons" ]; then
      echo "  the site DID reload in the background — the break is downstream," \
           "in the polyfill -> NotificationService -> flutter_local_notifications leg" >&2
    elif [ -z "$now_pid" ] || [ "$now_pid" != "$baseline_pid" ]; then
      echo "  the app process is GONE (pid ${baseline_pid:-none} -> ${now_pid:-none}) —" \
           "the OS reclaimed it while backgrounded, so the worker had no engine to" \
           "dispatch to. NOTIF-005-A accepts that; this is emulator memory pressure," \
           "not the dispatch leg." >&2
    elif [ "$worker_runs_now" -le "$worker_runs_before" ]; then
      echo "  the worker never ran — the break is in the trigger, before" \
           "NotificationRefreshWorker.doWork (WorkManager never dispatched it)" >&2
    else
      echo "  the site did NOT reload — the break is upstream," \
           "in the worker -> engine dispatch -> onBackgroundRefresh leg" >&2
    fi
    echo "  WebspaceBgRefresh logcat:" >&2
    bg_log | tail -20 | sed 's/^/    /' >&2
    dump_bg_diagnostics notif-refresh
    exit 1
  fi
  sleep 2
done

# Ties back into BUG-001: the site that just reloaded offscreen must
# still paint when brought back onstage.
adb shell am start -W -n "$component"
wait_for_pixels notif-foreground-dark 90 --expect-dominant "$dark"

# ---- Warm home-shortcut taps (HS-002 / HS-006 / INTEG-013) ----
#
# A tap on a pinned tile while the app is running is delivered as
# onNewIntent, not as a fresh launch: the siteId extra has to be drained
# from the *replaced* intent and routed through _handleShortcutIntent on
# the resume. Only an out-of-process driver produces that transition, so
# the in-process suite (integration_test/shortcut_behavior_test.dart)
# cannot cover these two.

echo "== Scenario G: warm shortcut tap switches sites (HS-002)"
adb shell am force-stop "$pkg"
adb shell am start -W -n "$component" \
  --es ws_diag_seed \
  "$(seed_pair_b64 dark.html "$dark_site_id" blue.html "$blue_site_id")" \
  --es siteId "$dark_site_id"
wait_for_pixels shortcut-cold-dark 180 --expect-dominant "$dark"

adb shell am start -W -n "$component" --es siteId "$blue_site_id"
wait_for_pixels shortcut-warm-switch-blue 90 --expect-dominant "$blue"

echo "== Scenario H: warm tap leaves the running session intact (HS-006)"
# Back to the dark site, drive it off its initUrl (the full-page link),
# then re-tap its shortcut: HS-006 resets to initUrl on cold launch only,
# so the live session must survive. A regression repaints dark here.
adb shell am start -W -n "$component" --es siteId "$dark_site_id"
wait_for_pixels shortcut-warm-back-dark 90 --expect-dominant "$dark"
adb shell input tap "$((w / 2))" "$((h / 2))"
wait_for_pixels shortcut-session-magenta 90 --expect-dominant "$magenta"
adb shell input keyevent 3
sleep 5
adb shell am start -W -n "$component" --es siteId "$dark_site_id"
wait_for_pixels shortcut-warm-preserves-session 90 --expect-dominant "$magenta"

echo "White-screen lifecycle + shortcut tier passed."
