#!/usr/bin/env bash
# Verify the two export-compliance keys in an Info.plist agree before the
# build carrying it is handed to App Store Connect. Both Apple targets ship
# from the same declaration: ios/Runner/Info.plist (default) and
# macos/Runner/Info.plist.
#
# ITSAppUsesNonExemptEncryption is only half the declaration. Once Apple
# approves the uploaded encryption documentation it issues a compliance code,
# and the binary must carry it as ITSEncryptionExportComplianceCode. A build
# declaring `true` with the code absent compiles, archives and exports
# cleanly, produces a valid-looking IPA, and is rejected only by App Store
# Connect at upload:
#
#   Invalid Export Compliance Code. The export compliance key value [] in the
#   app's Info.plist doesn't match the key value of the app's export
#   compliance documentation. (ITMS-90592)
#
# Nothing between the edit and the upload notices, which is why this exists.
# See TOR-010 in openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md.
#
# Deliberately NOT wired into CI or `flutter build ipa`: the code does not
# exist until Apple finishes reviewing the documentation, so a commit-time
# gate would be red for the whole turnaround. This is a property of a
# submission, not of the source tree, so it runs on the fastlane deploy lanes.
#
# Usage: scripts/check_export_compliance.sh [path-to-Info.plist]

set -euo pipefail

PLIST="${1:-$(dirname "$0")/../ios/Runner/Info.plist}"

if [[ ! -f "$PLIST" ]]; then
  echo "ERROR: Info.plist not found: $PLIST" >&2
  exit 2
fi

# Print the first element following <key>$1</key>, whitespace trimmed. Empty
# when the key is absent.
plist_value_after_key() {
  awk -v key="$1" '
    index($0, "<key>" key "</key>") { found = 1; next }
    found {
      gsub(/^[ \t]+|[ \t\r]+$/, "")
      if ($0 == "") next
      print
      exit
    }
  ' "$PLIST"
}

declared=$(plist_value_after_key ITSAppUsesNonExemptEncryption)
code=$(plist_value_after_key ITSEncryptionExportComplianceCode |
  sed -e 's|^<string>||' -e 's|</string>$||')

case "$declared" in
  "")
    cat >&2 <<MSG
ERROR: $PLIST declares no ITSAppUsesNonExemptEncryption.

Omitting it does not skip the question; it stalls every submission on the
export-compliance prompt in App Store Connect instead.
MSG
    exit 1
    ;;
  "<true/>")
    if [[ -z "$code" ]]; then
      cat >&2 <<MSG
ERROR: ITSAppUsesNonExemptEncryption is <true/> but
ITSEncryptionExportComplianceCode is missing or empty.

App Store Connect will reject the upload with ITMS-90592:

  Invalid Export Compliance Code. The export compliance key value [] in the
  app's Info.plist doesn't match the key value of the app's export compliance
  documentation.

The code is issued after Apple approves the encryption documentation:
App Store Connect > My Apps > Webspace > App Information > App Encryption
Documentation. Add it to $PLIST as

  <key>ITSEncryptionExportComplianceCode</key>
  <string>the-code-apple-gave-you</string>

Do not invent a value. A wrong code is a false statement on a submission
form, not a rejected upload.
MSG
      exit 1
    fi
    ;;
  "<false/>")
    if [[ -n "$code" ]]; then
      cat >&2 <<MSG
ERROR: ITSAppUsesNonExemptEncryption is <false/> but
ITSEncryptionExportComplianceCode is set to "$code".

An exempt declaration carries no compliance code. This is the same mismatch
ITMS-90592 reports, in the other direction: drop the code key, or set the
declaration back to <true/>.
MSG
      exit 1
    fi
    ;;
  *)
    echo "ERROR: ITSAppUsesNonExemptEncryption has a non-boolean value: $declared" >&2
    exit 1
    ;;
esac

echo "OK: export compliance keys agree (ITSAppUsesNonExemptEncryption=$declared)."
