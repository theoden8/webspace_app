#!/usr/bin/env bash
# Whether a built app's Dart snapshot carries the search of addons.mozilla.org
# (WEBEXT-019). The search is compiled in only by a build made with
# --dart-define=WEBSPACE_EXTENSION_SEARCH=true, which an App Store build never
# is (App Review 3.2.2(i)); without the define the compiler leaves its code out,
# and with it the query's path is a string in the snapshot. That path is the
# literal amoSearchQuery builds (lib/services/web_extension_search_engine.dart);
# test/js/extension_search_build.test.js holds the two to each other.
#
# Usage: scripts/check_extension_search.sh <absent|present> <snapshot>
#   the snapshot is App.framework/App in an iOS or macOS bundle.
set -euo pipefail

want="${1:?usage: check_extension_search.sh <absent|present> <snapshot>}"
snapshot="${2:?usage: check_extension_search.sh <absent|present> <snapshot>}"
marker='/api/v5/addons/search/'

case "$want" in
  absent|present) ;;
  *) echo "::error::expected absent or present, got '$want'" >&2; exit 2 ;;
esac
[ -f "$snapshot" ] || { echo "::error::no Dart snapshot at $snapshot" >&2; exit 1; }

if LC_ALL=C grep -aqF "$marker" "$snapshot"; then found=present; else found=absent; fi
if [ "$found" != "$want" ]; then
  if [ "$want" = absent ]; then
    echo "::error::$snapshot carries the extension search; build it again without --dart-define=WEBSPACE_EXTENSION_SEARCH=true" >&2
  else
    echo "::error::$snapshot has no extension search; build it with --dart-define=WEBSPACE_EXTENSION_SEARCH=true" >&2
  fi
  exit 1
fi
echo "OK: extension search $found in $snapshot"
