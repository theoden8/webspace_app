#!/usr/bin/env bash
# Builds the release files this machine can make into build/release: the Play
# APKs and bundle anywhere, the iOS ipa on macOS, and on Linux the AppImage
# (PLATFORM-013), unsigned, packed by linux/appimage/pack.sh as
# scripts/release_appimage.sh packs the signed one.
#
#   scripts/build_all.sh
#     On Linux, the AppImage for this machine's architecture (x86_64 or
#     aarch64), from snapcraft's build here: Ubuntu 24.04 and sudo, and a
#     cold WebKit build takes hours.
#
#   APPIMAGE_RUN=<run id> scripts/build_all.sh
#     On Linux, an AppImage for every architecture, from the AppDirs that run
#     of the Snap workflow kept; needs gh signed in, tar and zstd.
set -euxo pipefail

cd "$(dirname "$0")/.."

fail() { echo "build_all.sh: $1" >&2; exit 1; }

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

# Flutter's Gradle plugin names every APK app[-<abi>]-<flavor>-<mode>.apk
# whatever outputFileName says, so the release names are given here.
android() {
  fvm flutter build apk --flavor fmain --release
  fvm flutter build apk --flavor fmain --release --split-per-abi
  fvm flutter build appbundle --flavor fmain --release
  local apks=build/app/outputs/flutter-apk
  cp "$apks/app-fmain-release.apk" "$OUT/webspace-universal.apk"
  for abi in arm64-v8a armeabi-v7a x86_64; do
    cp "$apks/app-$abi-fmain-release.apk" "$OUT/webspace-$abi.apk"
  done
  cp build/app/outputs/bundle/fmainRelease/app-fmain-release.aab "$OUT/webspace.aab"
}

ios() {
  rm -rf build/ios/ipa
  fvm flutter build ipa --release
  cp build/ios/ipa/*.ipa "$OUT/webspace.ipa"
}

# The AppDir from snapcraft's prime/, as the Snap workflow makes it.
appdir_here() {
  local work=$1 arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) ;;
    *) fail "no AppImage is made for $arch" ;;
  esac
  # shellcheck disable=SC1091
  (. /etc/os-release && [ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ]) \
    || fail "the snap builds on Ubuntu 24.04 only (its base); on another host take CI's AppDirs with APPIMAGE_RUN=<run id>"
  command -v snapcraft >/dev/null || fail "snapcraft is not installed: sudo snap install snapcraft --classic"
  # The ccache directory the wpewebkit part names.
  sudo mkdir -p /var/cache/webspace-snap-ccache
  sudo snapcraft pack --destructive-mode
  sudo bash linux/appimage/build_appdir.sh prime "$work/AppDir-$arch"
  sudo chown -R "$(id -u):$(id -g)" "$work/AppDir-$arch"
}

appdirs_of_run() {
  local work=$1 run=$2 pair snap_arch arch tarball
  for c in gh tar zstd; do
    command -v "$c" >/dev/null || fail "$c is not installed"
  done
  for pair in amd64:x86_64 arm64:aarch64; do
    snap_arch="${pair%%:*}" arch="${pair#*:}"
    gh run download "$run" --name "webspace-appdir-$snap_arch" --dir "$work/$snap_arch"
    tarball="$work/$snap_arch/webspace-appdir-$snap_arch.tar.zst"
    [ -f "$tarball" ] || fail "run $run's webspace-appdir-$snap_arch holds no $(basename "$tarball")"
    mkdir "$work/AppDir-$arch"
    zstd -dc "$tarball" | tar -x --no-same-owner -C "$work/AppDir-$arch"
  done
}

appimage() {
  local work=build/appimage appdir arch
  # A failed local build leaves its AppDir root-owned.
  rm -rf "$work" 2>/dev/null || sudo rm -rf "$work"
  mkdir -p "$work"
  if [ -n "${APPIMAGE_RUN:-}" ]; then
    appdirs_of_run "$work" "$APPIMAGE_RUN"
  else
    appdir_here "$work"
  fi
  bash linux/appimage/fetch_tools.sh "$work/tools" >/dev/null
  for appdir in "$work"/AppDir-*; do
    arch="${appdir##*/AppDir-}"
    bash linux/appimage/pack.sh --appdir "$appdir" --out "$OUT/webspace-$arch.AppImage" --tools "$work/tools"
  done
}

android
case "$(uname -s)" in
  Darwin) ios ;;
  Linux) appimage ;;
esac
ls -l "$OUT"
