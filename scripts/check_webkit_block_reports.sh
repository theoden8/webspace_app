#!/usr/bin/env bash
# Whether a built iOS or macOS app carries WebKit's block reports (CB-023),
# which name a WebKit method Apple does not publish: compiled in only by a
# build made with --flavor direct (the Runner's WEBSPACE_DIRECT condition),
# never by one for the App Store (App Review 2.5.1). The method's name is a
# string in the Runner's binary exactly when the code is in it;
# test/js/webkit_block_reports_build.test.js holds the marker to the Swift.
#
# Usage: scripts/check_webkit_block_reports.sh <absent|present> <app bundle>
set -euo pipefail

want="${1:?usage: check_webkit_block_reports.sh <absent|present> <app bundle>}"
app="${2:?usage: check_webkit_block_reports.sh <absent|present> <app bundle>}"
marker='_webView:contentRuleListWithIdentifier:performedAction:forURL:'

case "$want" in
  absent|present) ;;
  *) echo "::error::expected absent or present, got '$want'" >&2; exit 2 ;;
esac
[ -d "$app" ] || { echo "::error::no app bundle at $app" >&2; exit 1; }

if LC_ALL=C grep -raqF "$marker" "$app"; then found=present; else found=absent; fi
if [ "$found" != "$want" ]; then
  if [ "$want" = absent ]; then
    echo "::error::$app carries WebKit's private block reports; build it again without --flavor direct" >&2
  else
    echo "::error::$app has no WebKit block reports; build it with --flavor direct" >&2
  fi
  exit 1
fi
echo "OK: WebKit block reports $found in $app"
