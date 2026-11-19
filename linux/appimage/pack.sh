#!/usr/bin/env bash
# Packs an AppDir build_appdir.sh made into the AppImage (PLATFORM-013),
# with the runtime and appimagetool linux/appimage/fetch_tools.sh fetched.
# The one way the file is made: CI packs it unsigned to run it
# (scripts/check_appimage.sh), and scripts/release_appimage.sh packs it signed,
# with the update information that points at the GitHub releases and the
# .zsync file AppImageUpdate reads beside it.
#
#   pack.sh --appdir DIR --out FILE --tools DIR [--key FINGERPRINT --update-info STRING]
#
# --key signs with that key through the user's own gpg-agent and pinentry;
# the passphrase never passes through here. SOURCE_DATE_EPOCH, when set,
# dates the image's files, so the same AppDir packs to the same bytes.
set -euo pipefail

appdir='' out='' tools='' key='' info=''
while [ $# -gt 0 ]; do
  case "$1" in
    --appdir) appdir=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --tools) tools=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --update-info) info=$2; shift 2 ;;
    *) echo "pack.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
for pair in "appdir:$appdir" "out:$out" "tools:$tools"; do
  [ -n "${pair#*:}" ] || { echo "pack.sh: --${pair%%:*} is required" >&2; exit 2; }
done
fail() { echo "pack.sh: $1" >&2; exit 1; }
appdir="$(realpath "$appdir")"
tools="$(realpath "$tools")"
out="$(realpath -m "$out")"

case "$(basename "$(dirname "$(compgen -G "$appdir/usr/lib/*/libWPEWebKit-2.0.so.1" | head -1)")")" in
  x86_64-linux-gnu) arch=x86_64 ;;
  aarch64-linux-gnu) arch=aarch64 ;;
  *) fail "$appdir holds no WebKit of an architecture an AppImage is made for" ;;
esac
host="$(uname -m)"
tool="$tools/appimagetool-$host.AppImage"
[ -x "$tool" ] || fail "no appimagetool for $host in $tools"
[ -f "$tools/runtime-$arch" ] || fail "no runtime for $arch in $tools"

args=(--no-appstream --runtime-file "$tools/runtime-$arch")
[ -z "$info" ] || args+=(--updateinformation "$info")
[ -z "$key" ] || args+=(--sign --sign-key "$key")

rm -f "$out" "$out.zsync"
mkdir -p "$(dirname "$out")"
# appimagetool guesses update information from a CI's variables when given
# none, and zsyncmake writes the .zsync into the directory it runs in.
(
  cd "$(dirname "$out")"
  env -u GITHUB_TOKEN -u GITHUB_REPOSITORY -u TRAVIS_REPO_SLUG -u CI_COMMIT_REF_NAME \
    -u APPIMAGETOOL_SIGN_PASSPHRASE ARCH="$arch" APPIMAGE_EXTRACT_AND_RUN=1 \
    "$tool" "${args[@]}" "$appdir" "$out"
)
[ -x "$out" ] || fail "appimagetool made no $out"
if [ -n "$info" ]; then
  [ -s "$out.zsync" ] || fail "appimagetool made no $out.zsync"
fi
echo "pack.sh: $out"
