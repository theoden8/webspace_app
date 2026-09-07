#!/usr/bin/env bash
# Sign a built macOS .app for one of the three ways it leaves this repo.
#
#   adhoc  local/CI artifact: re-sign with an entitlement set an ad-hoc
#          signature can actually back
#   devid  Developer ID + hardened runtime, notarized and stapled -> .zip
#   mas    Apple Distribution + provisioning profiles -> .pkg for App Store
#          Connect
#
# Why this exists rather than Xcode signing settings: the committed
# entitlements name their groups as $(AppIdentifierPrefix)…, which only
# resolves when the build has a DEVELOPMENT_TEAM. CI has no certificate, so it
# builds with an empty team and an ad-hoc signature, and taskgated SIGKILLs
# that combination at launch as "Code Signature Invalid" — the artifact is
# unlaunchable on any machine. Signing after the build lets one unsigned build
# serve all three paths, and keeps the release identity out of the project
# file.
#
# Usage: scripts/sign_macos.sh <adhoc|devid|mas> [path-to-.app]
#
# Environment:
#   WEBSPACE_TEAM_ID            team the entitlements are prefixed with
#   MACOS_SIGN_IDENTITY         codesign identity (defaults per mode)
#   MACOS_INSTALLER_IDENTITY    mas: productbuild identity
#   MACOS_PROVISION_PROFILE     mas: .provisionprofile for the app
#   MACOS_EXT_PROVISION_PROFILE mas: .provisionprofile for the share extension
#   NOTARY_PROFILE              devid: notarytool keychain profile name
#   NOTARY_KEY/_ID/_ISSUER      devid: App Store Connect API key instead
#
# See docs/releasing-macos.md.

set -euo pipefail

MODE="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APP=$(ls -d "$REPO_ROOT"/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1 || true)
APP="${2:-$DEFAULT_APP}"

TEAM_ID="${WEBSPACE_TEAM_ID:-7NGC2P87LM}"
APP_ENTITLEMENTS="$REPO_ROOT/macos/Runner/Release.entitlements"
EXT_ENTITLEMENTS="$REPO_ROOT/macos/ShareExtension/ShareExtension.entitlements"

usage() {
  awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

case "$MODE" in
  adhoc|devid|mas) ;;
  *) usage ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: macOS only." >&2; exit 2; }
[[ -n "$APP" && -d "$APP" ]] || {
  echo "ERROR: no .app at '${APP:-<none>}'. Run: fvm flutter build macos --release" >&2
  exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

plist_keys() {
  plutil -convert xml1 -o - "$1" |
    sed -n 's|.*<key>\(.*\)</key>.*|\1|p' | sort -u
}

plist_delete() {
  /usr/libexec/PlistBuddy -c "Delete :$2" "$1" 2>/dev/null || true
}

# Sign with what the build embedded, not with the committed file: the build
# resolves $(AppIdentifierPrefix) from DEVELOPMENT_TEAM, adds what the project
# generates from ENABLE_* build settings (network.client), and adds what the
# provisioning profile carries (application-identifier, team-identifier). The
# file alone has none of those, and a sandboxed browser signed without
# network.client loads nothing and reports nothing.
materialize_entitlements() {
  local bundle="$1" src="$2" out="$3"
  codesign -d --entitlements :- "$bundle" 2>/dev/null | sed -n '/<?xml/,$p' > "$out" || true
  if [[ ! -s "$out" ]]; then
    sed "s/[$](AppIdentifierPrefix)/${TEAM_ID}./g" "$src" > "$out"
  fi
  # Xcode grants this whenever it signs for development. A distribution build
  # that keeps it is rejected by notarization and by App Store Connect.
  plist_delete "$out" com.apple.security.get-task-allow
  if [[ "$MODE" == "adhoc" ]]; then
    # An ad-hoc signature cannot back a team-scoped group, and the launch
    # failure it causes is a SIGKILL with no dialog.
    plist_delete "$out" com.apple.security.application-groups
    plist_delete "$out" keychain-access-groups
  fi
  assert_grants_present "$src" "$out"
}

# The other direction: a capability the file declares but the build never
# granted (an ENABLE_* setting left at NO) would be signed away here.
assert_grants_present() {
  local src="$1" out="$2" missing
  missing=$(comm -23 <(plist_keys "$src") <(plist_keys "$out") || true)
  if [[ "$MODE" == "adhoc" ]]; then
    missing=$(printf '%s\n' "$missing" |
      grep -v -e '^com.apple.security.application-groups$' -e '^keychain-access-groups$' || true)
  fi
  [[ -z "${missing//[[:space:]]/}" ]] && return 0
  echo "ERROR: $src declares entitlements the built bundle does not carry:" >&2
  printf '%s\n' "$missing" | sed '/^$/d; s/^/  /' >&2
  echo "The file and the ENABLE_* build settings have to agree (PLATFORM-006)." >&2
  exit 1
}

sign_one() {
  local target="$1" entitlements="${2:-}"
  local args=(--force --sign "$IDENTITY" --timestamp)
  [[ "$MODE" == "adhoc" ]] && args=(--force --sign -)
  [[ "$MODE" == "devid" ]] && args+=(--options runtime)
  [[ -n "$entitlements" ]] && args+=(--entitlements "$entitlements")
  codesign "${args[@]}" "$target"
}

case "$MODE" in
  adhoc) IDENTITY="-" ;;
  devid) IDENTITY="${MACOS_SIGN_IDENTITY:-Developer ID Application}" ;;
  mas)   IDENTITY="${MACOS_SIGN_IDENTITY:-Apple Distribution}" ;;
esac

if [[ "$MODE" == "mas" ]]; then
  : "${MACOS_PROVISION_PROFILE:?set MACOS_PROVISION_PROFILE to the app's .provisionprofile}"
  : "${MACOS_EXT_PROVISION_PROFILE:?set MACOS_EXT_PROVISION_PROFILE to the extension's .provisionprofile}"
  # ITSAppUsesNonExemptEncryption without its matching compliance code is
  # rejected by App Store Connect at upload, after the build (EXPORT-001).
  "$REPO_ROOT/scripts/check_export_compliance.sh" "$REPO_ROOT/macos/Runner/Info.plist"
  cp "$MACOS_PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

materialize_entitlements "$APP" "$APP_ENTITLEMENTS" "$WORK/app.entitlements"

# Nested code first: a signature over a bundle whose contents change
# afterwards is invalid, and codesign will not tell you until launch.
while IFS= read -r -d '' nested; do
  sign_one "$nested"
done < <(find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null)

while IFS= read -r -d '' appex; do
  [[ "$MODE" == "mas" ]] && cp "$MACOS_EXT_PROVISION_PROFILE" "$appex/Contents/embedded.provisionprofile"
  materialize_entitlements "$appex" "$EXT_ENTITLEMENTS" "$WORK/ext.entitlements"
  sign_one "$appex" "$WORK/ext.entitlements"
done < <(find "$APP/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0 2>/dev/null)

sign_one "$APP" "$WORK/app.entitlements"
codesign --verify --deep --strict --verbose=2 "$APP"

OUT_DIR="$REPO_ROOT/build/macos"
mkdir -p "$OUT_DIR"
BASE="$(basename "$APP" .app)"

case "$MODE" in
  adhoc)
    cat <<'MSG'
Ad-hoc signed. This artifact launches, but it is not a distributable build:
no team means flutter_secure_storage fails (-34018), so cookies and proxy
credentials do not persist, and the share extension's app group is gone.
Gatekeeper still quarantines it on download. See docs/releasing-macos.md.
MSG
    ;;
  devid)
    ZIP="$OUT_DIR/$BASE-macos.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    else
      : "${NOTARY_KEY:?set NOTARY_PROFILE, or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER}"
      xcrun notarytool submit "$ZIP" \
        --key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}" --wait
    fi
    xcrun stapler staple "$APP"
    # The notarized ticket is stapled to the .app, so the zip has to be made
    # again from the stapled bundle.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type exec --verbose=2 "$APP"
    echo "Notarized and stapled: $ZIP"
    ;;
  mas)
    PKG="$OUT_DIR/$BASE-macos.pkg"
    productbuild --component "$APP" /Applications \
      --sign "${MACOS_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}" "$PKG"
    cat <<MSG
Signed for the Mac App Store: $PKG

Upload with either:
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey <id> --apiIssuer <issuer>
  bundle exec fastlane deliver --platform osx --pkg "$PKG"
MSG
    ;;
esac
