#!/usr/bin/env bash
# Checks the AppImage (PLATFORM-013). From the AppDir: every library an ELF
# file in it links resolves inside it, but those linux/appimage/excludelist
# leaves to the machine, so nothing it runs depends on the build host's
# libraries. Then runs it with one site, in a home of its own and a session bus
# of its own: launched with a webspace://open link to the site, the app owns
# its application ID on the bus, a second launch hands over and exits
# (PLATFORM-011), and the site's page is requested, with WebKit's web and
# network processes started from the bundle (linux/wpe_root.patch), not from
# /usr. The link goes to the first launch: the app reads a handed-over link at
# its cold launch and then on a resume, which a display with no window manager
# never gives it, and the AppImage starts fast enough to have read before a
# second launch's arrives.
#
#   scripts/check_appimage.sh APPDIR [APPIMAGE]
#
# With APPIMAGE, runs it as a user would, mounted through FUSE; without, runs
# APPDIR/AppRun. Needs Xvfb, python3, gdbus and dbus-run-session.
set -euo pipefail

appdir="$(realpath "${1:?usage: check_appimage.sh APPDIR [APPIMAGE]}")"
appimage="${2:+$(realpath "$2")}"
root="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${WEBSPACE_CHECK_BUS:-}" ]; then
  WEBSPACE_CHECK_BUS=1 exec dbus-run-session -- bash "$0" "$@"
fi

id="$(sed -n 's/^  set(APPLICATION_ID "\([[:alnum:]_.]*\)")$/\1/p' "$root/linux/CMakeLists.txt")"
[ -n "$id" ] || { echo "::error::no default APPLICATION_ID in linux/CMakeLists.txt" >&2; exit 1; }

# Every soname resolves inside the AppDir or is the machine's: one the
# excludelist names, or one such a library links in turn.
declare -A excluded
while IFS=$'\t' read -r soname _; do
  case "$soname" in ''|'#'*) continue ;; esac
  excluded[$soname]=1
  host="$(ldconfig -p | awk -v s="$soname" '$1 == s { print $NF; exit }')"
  [ -n "$host" ] || continue
  while read -r dep arrow _; do
    [ "$arrow" = '=>' ] && excluded[$dep]=1
  done < <(ldd "$host" 2>/dev/null || true)
done < "$root/linux/appimage/excludelist"
outside=()
while IFS= read -r -d '' f; do
  [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || continue
  while read -r soname arrow path _; do
    [ "$arrow" = '=>' ] || continue
    [ -z "${excluded[$soname]:-}" ] || continue
    case "$path" in
      "$appdir"/*) ;;
      not) [ "$soname" = libjvm.so ] || outside+=("${f#"$appdir"/}: $soname not found") ;;
      *) outside+=("${f#"$appdir"/}: $soname from $path") ;;
    esac
  done < <(ldd "$f" 2>/dev/null || true)
done < <(find "$appdir" -type f -print0)
if [ "${#outside[@]}" -gt 0 ]; then
  printf '::error::%s\n' "${outside[@]}" | sort -u | head -40 >&2
  exit 1
fi
echo "every library in $appdir resolves inside it or is the machine's"

work="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

fail() {
  echo "::error::$1" >&2
  echo "--- app log"; tail -80 "$work/app.log" || true
  echo "--- http log"; cat "$work/http.log" || true
  exit 1
}

export HOME="$work/home"
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
mkdir -p "$HOME"
if [ -n "$appimage" ]; then run=("$appimage"); else run=("$appdir/AppRun"); fi

mkdir "$work/www"
printf '<!doctype html><title>appimage check</title><p>appimage check</p>\n' > "$work/www/check.html"
python3 -m http.server 8766 --bind 127.0.0.1 --directory "$work/www" > "$work/http.log" 2>&1 &
pids+=($!)
if [ -z "${DISPLAY:-}" ]; then
  Xvfb :98 -screen 0 1280x800x24 > "$work/xvfb.log" 2>&1 &
  pids+=($!)
  export DISPLAY=:98
fi

url=http://127.0.0.1:8766/check.html
mkdir -p "$HOME/.local/share/$id"
python3 -c '
import json, sys
site = {"siteId": "appimagecheck01", "initUrl": sys.argv[1], "currentUrl": sys.argv[1], "name": "Check"}
print(json.dumps({"flutter.webViewModels": [json.dumps(site)]}))' "$url" > "$HOME/.local/share/$id/shared_preferences.json"

owned() {
  local reply
  reply="$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner "$id" 2>/dev/null)" || return 1
  grep -q true <<<"$reply"
}

link="webspace://open?url=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url")"
"${run[@]}" "$link" > "$work/app.log" 2>&1 &
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

start=$SECONDS
timeout 30 "${run[@]}" > "$work/second.log" 2>&1 \
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
  pid="$(pgrep -f "wpe-webkit-2.0/$p" | head -1)" || fail "WebKit's $p is not running"
  exe="$(readlink -f "/proc/$pid/exe")"
  case "$exe" in
    /usr/*) fail "WebKit's $p runs from $exe, not from the AppImage" ;;
  esac
  echo "WebKit's $p runs from $exe"
done
echo "the site's page was requested, with WebKit's processes running from the AppImage"
