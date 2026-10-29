#!/usr/bin/env bash
# Runs the Linux runner's screen sharing (SHARE-018, linux/screen_share.cc)
# against a real PipeWire stream and a stand-in for the desktop portal
# (mock_portal.c), driving its channel as Dart does (harness.cc): a share at
# the asked rate with the screen's colours, a cancelled dialog, the desktop's
# own Stop, and a stop and a second share. No other tier runs this code: the
# Dart tiers mock the channel, and the Linux build only compiles it.
#
# It then builds the source with each planted mistake below and fails unless
# the harness catches every one.
#
# Needs a C and C++ compiler, the pkg-config modules gtk+-3.0,
# libpipewire-0.3 and gio-unix-2.0, pipewire, wireplumber, gst-launch-1.0
# with the pipewire plugin, pw-dump, jq and dbus-run-session; and Flutter's
# Linux embedder (flutter_linux/ and libflutter_linux_gtk.so) from
# linux/flutter/ephemeral after a Linux build, from $FLUTTER_LINUX, or from
# the Flutter .fvmrc pins under ~/fvm. Skips (0) when any is missing, and
# fails instead with CI=true, so in CI it is a gate and not a skip.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
here="$root/test/linux/screen_share"

missing() {
  if [ "${CI:-}" = "true" ]; then
    echo "screen_share check: $1 is missing" >&2
    exit 1
  fi
  echo "screen_share check: $1 is missing, skipping"
  exit 0
}

if [ -z "${WS_SCREEN_SHARE_BUS:-}" ]; then
  for tool in cc pkg-config pipewire wireplumber gst-launch-1.0 pw-dump jq dbus-run-session; do
    command -v "$tool" > /dev/null || missing "$tool"
  done
  command -v clang++ > /dev/null || command -v g++ > /dev/null || missing "a C++ compiler"
  pkg-config --exists gtk+-3.0 libpipewire-0.3 gio-unix-2.0 || missing "a pkg-config module"
  gst-inspect-1.0 pipewiresink > /dev/null 2>&1 || missing "GStreamer's pipewiresink"
  embedder="${FLUTTER_LINUX:-}"
  if [ -z "$embedder" ] && [ -f "$root/linux/flutter/ephemeral/libflutter_linux_gtk.so" ]; then
    embedder="$root/linux/flutter/ephemeral"
  fi
  if [ -z "$embedder" ]; then
    version="$(jq -r .flutter "$root/.fvmrc")"
    embedder="$HOME/fvm/versions/$version/bin/cache/artifacts/engine/linux-x64"
  fi
  [ -f "$embedder/libflutter_linux_gtk.so" ] || missing "Flutter's Linux embedder"
  # The rest runs on a session bus of its own, which only the portal owns.
  exec env WS_SCREEN_SHARE_BUS=1 FLUTTER_LINUX="$embedder" dbus-run-session -- "$0" "$@"
fi

work="$(mktemp -d /tmp/ws-share.XXXXXX)"
export XDG_RUNTIME_DIR="$work/run"
mkdir -m 700 "$XDG_RUNTIME_DIR"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null || true; done
  wait 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

cxx="$(command -v clang++ || command -v g++)"
flags=(-std=c++14 -Wall -Werror -O1)
deps=$(pkg-config --cflags --libs gtk+-3.0 libpipewire-0.3 gio-unix-2.0)

cc -O1 -o "$work/mock_portal" "$here/mock_portal.c" $(pkg-config --cflags --libs gio-unix-2.0)

build() {
  local source="$1" out="$2"
  "$cxx" "${flags[@]}" -o "$out" "$here/harness.cc" \
    -DSCREEN_SHARE_SOURCE="\"$source\"" -I"$root/linux" -I"$FLUTTER_LINUX" $deps \
    -L"$FLUTTER_LINUX" -lflutter_linux_gtk -Wl,-rpath,"$FLUTTER_LINUX"
}
build "$root/linux/screen_share.cc" "$work/harness"

pipewire > "$work/pipewire.log" 2>&1 & pids+=($!)
sleep 1
wireplumber > "$work/wireplumber.log" 2>&1 & pids+=($!)
sleep 1
# Each run gets a source of its own: one a closed stream was linked to can
# stall the next one linked to it.
runs=0
source_up() {
  runs=$((runs + 1))
  local name="ws-test-screen-$runs"
  gst-launch-1.0 -q videotestsrc pattern=smpte is-live=true \
    ! video/x-raw,format=BGRx,width=640,height=480,framerate=30/1 \
    ! pipewiresink mode=provide \
      stream-properties="props,media.class=Video/Source,node.name=$name" \
    > "$work/gst.log" 2>&1 &
  source=$!
  node=""
  for _ in $(seq 20); do
    node="$(pw-dump 2> /dev/null | jq -r --arg name "$name" '.[]
      | select(.type == "PipeWire:Interface:Node")
      | select(.info.props["node.name"] == $name) | .id' | head -1)"
    [ -n "$node" ] && return 0
    sleep 0.5
  done
  echo "screen_share check: the test source never appeared" >&2
  cat "$work/pipewire.log" "$work/wireplumber.log" "$work/gst.log" >&2
  exit 1
}

# Runs [harness] in [scenario] against a fresh source and a portal that
# answers as [hostile] says (none: the real portal's answers); its exit status.
run() {
  local harness="$1" scenario="$2" hostile="${3:-}" code=0 close=""
  [ "$scenario" = declined ] && code=1
  [ "$scenario" = desktop_stops ] && close=2
  source_up
  PORTAL_NODE="$node" PORTAL_START_CODE="$code" PORTAL_CLOSE_AFTER="$close" \
    PORTAL_HOSTILE="$hostile" "$work/mock_portal" > "$work/portal.log" 2>&1 &
  local portal=$!
  sleep 0.3
  local status=0
  timeout 60 "$harness" "$scenario" || status=$?
  kill "$portal" "$source" 2> /dev/null || true
  wait "$portal" "$source" 2> /dev/null || true
  return "$status"
}

failed=0
for scenario in share declined desktop_stops; do
  echo "== $scenario"
  if ! run "$work/harness" "$scenario"; then
    failed=1
    sed 's/^/  /' "$work/portal.log"
  fi
done
# A portal that is not the real one (a process that took its bus name) is
# refused rather than followed or crashed on.
for hostile in foreign_session bad_session fd_index_oob fd_index_neg; do
  echo "== refused: $hostile"
  if ! run "$work/harness" refused "$hostile"; then
    failed=1
    sed 's/^/  /' "$work/portal.log"
  fi
done
[ "$failed" = 0 ] || { echo "screen_share check: FAILED" >&2; exit 1; }

# Each planted mistake: a name, the scenario that must catch it (with the
# portal's answers, after a colon), and the edit that plants it.
mistakes=(
  "trusts_any_session|refused:foreign_session|s/^      if (share_->expected_session != session) {/      if (false) {/"
  "channels|share|s/red_ = 2, green_ = 1, blue_ = 0;/red_ = 0, green_ = 1, blue_ = 2;/"
  "unthrottled|share|s/^  if (now >= due) {/  if (true) {/"
  "deaf_to_the_desktops_stop|desktop_stops|s/^  host->end(true);/  return;/"
  "takes_a_cancel_as_a_pick|declined|s/^  if (code != 0) {/  if (false) {/"
)
for mistake in "${mistakes[@]}"; do
  IFS='|' read -r name catch edit <<< "$mistake"
  scenario="${catch%%:*}"
  hostile=""
  [ "$catch" != "$scenario" ] && hostile="${catch#*:}"
  planted="$work/$name.cc"
  sed "$edit" "$root/linux/screen_share.cc" > "$planted"
  if cmp -s "$planted" "$root/linux/screen_share.cc"; then
    echo "screen_share check: the edit for $name no longer applies" >&2
    exit 1
  fi
  build "$planted" "$work/harness_$name"
  echo "== planted: $name ($scenario)"
  if run "$work/harness_$name" "$scenario" "$hostile" > "$work/$name.log" 2>&1; then
    cat "$work/$name.log"
    echo "screen_share check: the harness missed the planted $name" >&2
    exit 1
  fi
  grep '^FAIL' "$work/$name.log" | sed 's/^/  caught: /'
done
echo "screen_share check: passed, and caught ${#mistakes[@]} planted mistakes"
