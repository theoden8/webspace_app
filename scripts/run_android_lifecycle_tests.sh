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
mkdir -p "$artifacts"

www="$(mktemp -d)"
server_log="$www/server.log"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  adb shell settings put global always_finish_activities 0 >/dev/null 2>&1 || true
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

seed_b64() { # $1 = page basename, $2 = siteId
  printf '{"sites":[{"name":"Diag","url":"%s/%s","siteId":"%s"}]}' \
    "$base" "$1" "$2" | base64 | tr -d '\n'
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
adb shell pm clear "$pkg" >/dev/null

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

echo "White-screen lifecycle tier passed."
