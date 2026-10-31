#!/usr/bin/env bash
# Runs the installed webspace snap with one site and checks what only a
# confined run shows (PLATFORM-012): the app starts with every library it
# links found in the snap and its runtimes, and owns its application ID on
# the session bus through the dbus slot; a second launch with a
# webspace://open link hands it over and exits (PLATFORM-011); the first
# opens the site, whose page is requested, with WebKit's web and network
# processes started from the snap's copies through the layout.
#
#   dbus-run-session -- scripts/check_snap.sh
#
# Needs the snap installed with its content plugs connected, Xvfb, python3,
# gdbus and a session bus. Prints the AppArmor denials the run caused either
# way.
set -euo pipefail

: "${DBUS_SESSION_BUS_ADDRESS:?run under dbus-run-session}"
root="$(cd "$(dirname "$0")/.." && pwd)"
id="$(sed -n 's/^  set(APPLICATION_ID "\([a-z.]*\)")$/\1/p' "$root/linux/CMakeLists.txt")"
[ -n "$id" ] || { echo "::error::no default APPLICATION_ID in linux/CMakeLists.txt" >&2; exit 1; }

work="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  echo "--- AppArmor denials for the snap"
  sudo -n journalctl -k --no-pager 2>/dev/null | grep 'apparmor="DENIED"' | grep 'snap\.webspace' | tail -40 || true
}
trap cleanup EXIT

fail() {
  echo "::error::$1" >&2
  echo "--- app log"; tail -60 "$work/app.log" || true
  echo "--- http log"; cat "$work/http.log" || true
  echo "--- libraries not found, as the app's shell resolves them"
  snap run --shell webspace -c '
    for f in "$SNAP"/opt/webspace/webspace_app "$SNAP"/opt/webspace/lib/*.so \
             "$SNAP"/usr/libexec/wpe-webkit-2.0/* "$SNAP"/usr/lib/*/libWPEWebKit-2.0.so.*; do
      ldd "$f" 2>&1 | sed -n "s|^[[:space:]]*\([^ ]*\) => not found|$f: \1|p"
    done' || true
  exit 1
}

mkdir "$work/www"
printf '<!doctype html><title>snap check</title><p>snap check</p>\n' > "$work/www/check.html"
python3 -m http.server 8765 --bind 127.0.0.1 --directory "$work/www" > "$work/http.log" 2>&1 &
pids+=($!)
Xvfb :99 -screen 0 1280x800x24 > "$work/xvfb.log" 2>&1 &
pids+=($!)
export DISPLAY=:99

# One site, seeded where shared_preferences reads it inside the snap.
url=http://127.0.0.1:8765/check.html
python3 -c '
import json, sys
site = {"siteId": "snapcheck01", "initUrl": sys.argv[1], "currentUrl": sys.argv[1], "name": "Check"}
print(json.dumps({"flutter.webViewModels": [json.dumps(site)]}))' "$url" \
  | snap run --shell webspace -c "d=\"\${XDG_DATA_HOME:-\$HOME/.local/share}/$id\" && mkdir -p \"\$d\" && cat > \"\$d/shared_preferences.json\""

owned() {
  local reply
  reply="$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner "$id" 2>/dev/null)" || return 1
  grep -q true <<<"$reply"
}

snap run webspace > "$work/app.log" 2>&1 &
app=$!
pids+=("$app")
for _ in $(seq 90); do
  owned && break
  kill -0 "$app" 2>/dev/null || break
  sleep 1
done
kill -0 "$app" 2>/dev/null || fail "the app exited"
owned || fail "the app does not own $id on the session bus"
echo "the app runs and owns $id"

link="webspace://open?url=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url")"
start=$SECONDS
timeout 30 snap run webspace "$link" > "$work/second.log" 2>&1 \
  || fail "a second launch did not hand over and exit: $(cat "$work/second.log")"
echo "a second launch handed over and exited after $((SECONDS - start)) s"

for _ in $(seq 120); do
  grep -q 'GET /check.html' "$work/http.log" && break
  kill -0 "$app" 2>/dev/null || break
  sleep 1
done
kill -0 "$app" 2>/dev/null || fail "the first instance exited"
grep -q 'GET /check.html' "$work/http.log" || fail "the site's page was never requested"
for p in WPEWebProcess WPENetworkProcess; do
  pgrep -f "wpe-webkit-2.0/$p" > /dev/null || fail "WebKit's $p is not running"
done
echo "the site's page was requested, with WebKit's processes running from the snap"
