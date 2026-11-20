#!/usr/bin/env bash
# Builds release files into build/release: the Play APKs and bundle
# (android) anywhere, the iOS ipa (ios) on macOS, and the AppImage (appimage,
# PLATFORM-013) on Linux. A target replaces only its own files there.
#
# The AppImage is packed by linux/appimage/pack.sh as
# scripts/release_appimage.sh packs it: signed by the release key
# linux/appimage/signing_key.asc names, whose secret half must be in this
# user's gpg, and pointing its updates, with the .zsync beside it, at the
# latest GitHub release of origin's repository (GH_REPO=owner/name for
# another). Each signature is checked against that key. Needs gpg and node.
#
#   scripts/build_all.sh [android] [ios] [appimage]
#     The targets named, or every one this machine builds.
#
#     The AppImage is this machine's architecture's (x86_64 or aarch64), from
#     snapcraft's build: on Ubuntu 24.04 here, with sudo; elsewhere in LXD or
#     Multipass, with podman or docker for the AppDir. A cold WebKit build
#     takes hours.
#
#   APPIMAGE_RUN=<run id> scripts/build_all.sh appimage
#     An AppImage for every architecture, from the AppDirs that run of the
#     Snap workflow kept (the number in its URL, .../actions/runs/<run id>, or
#     `gh run list --workflow snap.yml`); needs gh signed in, tar and zstd.
set -euxo pipefail

cd "$(dirname "$0")/.."

fail() { echo "build_all.sh: $1" >&2; exit 1; }
# shellcheck source=linux/appimage/release_names.sh
. linux/appimage/release_names.sh

OUT=build/release
mkdir -p "$OUT"

# Flutter's Gradle plugin names every APK app[-<abi>]-<flavor>-<mode>.apk
# whatever outputFileName says, so the release names are given here.
android() {
  rm -f "$OUT"/*.apk "$OUT/webspace.aab"
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
  rm -f "$OUT/webspace.ipa"
  rm -rf build/ios/ipa
  fvm flutter build ipa --release
  cp build/ios/ipa/*.ipa "$OUT/webspace.ipa"
}

# The AppDir from the tree snapcraft primed, as the Snap workflow makes it.
# On Ubuntu 24.04, the snap's base, snapcraft builds here and leaves it in
# prime/. Elsewhere snapcraft builds in its own LXD or Multipass instance, the
# tree is the snap's contents (the same files), and build_appdir.sh, which
# takes the base's libraries, runs in an Ubuntu 24.04 container.
appdir_here() {
  local work=$1 arch snap_arch snap engine snapcraft
  arch="$(uname -m)"
  case "$arch" in
    x86_64) snap_arch=amd64 ;;
    aarch64) snap_arch=arm64 ;;
    *) fail "no AppImage is made for $arch" ;;
  esac
  # snapd puts its bin directory on PATH from the next login.
  snapcraft="$(command -v snapcraft || compgen -G '/snap/bin/snapcraft' || compgen -G '/var/lib/snapd/snap/bin/snapcraft')" \
    || fail "snapcraft is not installed (snap install snapcraft --classic); or take CI's AppDirs with APPIMAGE_RUN=<run id>"
  rm -f ./*_"$snap_arch".snap
  # shellcheck disable=SC1091
  if (. /etc/os-release && [ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ]); then
    # The ccache directory the wpewebkit part names.
    sudo mkdir -p /var/cache/webspace-snap-ccache
    sudo "$snapcraft" pack --destructive-mode
    sudo bash linux/appimage/build_appdir.sh prime "$work/AppDir-$arch"
  else
    engine="$(command -v podman || command -v docker)" \
      || fail "building the AppDir off Ubuntu 24.04 needs podman or docker"
    # A user added to the lxd group has it from the next login; sg gives it now.
    if [[ " $(id -nG "$(id -un)") " == *" lxd "* && " $(id -nG) " != *" lxd "* ]]; then
      sg lxd -c "$(printf '%q ' "$snapcraft" pack)"
    else
      "$snapcraft" pack
    fi
    snap="$(compgen -G "./*_$snap_arch.snap" | head -1)" || fail "snapcraft made no $snap_arch snap"
    # shellcheck disable=SC2016 # the container's shell expands them
    "$engine" run --rm -v "$PWD:/src:ro,z" -v "$PWD/$work:/work:z" -w /src \
      docker.io/library/ubuntu:24.04 bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends squashfs-tools \
          $(bash linux/appimage/build_appdir.sh packages) >/dev/null
        unsquashfs -q -d /work/snap-root "$1"
        bash linux/appimage/build_appdir.sh /work/snap-root "/work/AppDir-$2"
        rm -rf /work/snap-root
      ' _ "$snap" "$arch"
  fi
  # Root's in the container or under sudo; a rootless podman's is already ours.
  [ -O "$work/AppDir-$arch" ] || sudo chown -R "$(id -u):$(id -g)" "$work/AppDir-$arch"
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

# What signs the AppImage and where its updates come from, read before a
# build that takes hours.
appimage_signer() {
  local c
  for c in gpg node git; do
    command -v "$c" >/dev/null || fail "$c is not installed"
  done
  KEY=linux/appimage/signing_key.asc
  [ -f "$KEY" ] || fail "no $KEY: make the release key with scripts/release_appimage.sh key"
  FPR="$(gpg --with-colons --show-keys "$KEY" | awk -F: '$1 == "fpr" { print $10; exit }')"
  gpg --list-secret-keys "$FPR" >/dev/null 2>&1 \
    || fail "this machine holds no secret key for $FPR: gpg --import your backup of it"
  local owed
  owed="$(node tool/check_bundle_licences.js --count-owed linux/appimage/licences_owed.tsv)"
  [ "$owed" -eq 0 ] || fail "$owed bundled packages are still owed, each waiting on what linux/appimage/licences_owed.tsv says"
  REPO="${GH_REPO:-$(git remote get-url origin | sed -n -E 's#^(https://|git@)github\.com[:/]([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')}"
  [[ "$REPO" == */* ]] || fail "origin is not on GitHub: name the repository updates come from with GH_REPO=owner/name"
}

appimage() {
  local work=build/appimage appdir arch commit pubspec version name info
  rm -f "$OUT"/*.AppImage "$OUT"/*.AppImage.zsync
  # A failed local build leaves its AppDir root-owned.
  rm -rf "$work" 2>/dev/null || sudo rm -rf "$work"
  mkdir -p "$work"
  if [ -n "${APPIMAGE_RUN:-}" ]; then
    appdirs_of_run "$work" "$APPIMAGE_RUN"
    commit="$(gh run view "$APPIMAGE_RUN" --json headSha --jq .headSha)"
    git cat-file -e "$commit^{commit}" 2>/dev/null || git fetch --quiet origin "$commit"
    pubspec="$(git show "$commit:pubspec.yaml")"
  else
    appdir_here "$work"
    commit=HEAD
    pubspec="$(cat pubspec.yaml)"
  fi
  version="$(sed -n 's/^version: *\([^+]*\)+.*$/\1/p' <<<"$pubspec")"
  [ -n "$version" ] || fail "no version in $commit's pubspec.yaml"
  # Dates the image's files, so the same AppDir packs to the same bytes.
  SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$commit")"
  export SOURCE_DATE_EPOCH
  bash linux/appimage/fetch_tools.sh "$work/tools" >/dev/null
  for appdir in "$work"/AppDir-*; do
    arch="${appdir##*/AppDir-}"
    name="$(appimage_name "$version" "$arch")"
    info="$(appimage_update_info "$REPO" "$arch")"
    bash linux/appimage/pack.sh --appdir "$appdir" --out "$OUT/$name" --tools "$work/tools" \
      --key "$FPR" --update-info "$info"
    node tool/appimage_signature.js "$OUT/$name" --key "$KEY" --update-info "$info"
  done
}

case "$(uname -s)" in
  Darwin) here=(android ios) ;;
  Linux) here=(android appimage) ;;
  *) here=(android) ;;
esac
[ $# -gt 0 ] || set -- "${here[@]}"
for target in "$@"; do
  case " ${here[*]} " in
    *" $target "*) ;;
    *) fail "this machine builds ${here[*]}, not $target" ;;
  esac
done
for target in "$@"; do
  [ "$target" != appimage ] || appimage_signer
done
for target in "$@"; do
  "$target"
done
ls -l "$OUT"
