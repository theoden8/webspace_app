#!/usr/bin/env bash
# Applies linux/wpe_root.patch to WebKit's tree before its build, so a WebKit
# moved whole, its /usr tree under another directory, finds its helper
# processes, its injected bundle and its inspector resources there when
# WEBSPACE_WPE_ROOT names that directory (PLATFORM-013, the AppImage). Unset,
# as in the snap, WebKit reads the paths it was configured with, as before. A
# tree it already patched is left as it is. Prints what it changed, for the
# copyright file linux/install_notices.sh writes.
#
#   wpe_root.sh --src WEBKIT_TREE
set -euo pipefail

src=''
while [ $# -gt 0 ]; do
  case "$1" in
    --src) src=$2; shift 2 ;;
    *) echo "wpe_root.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$src" ] || { echo "wpe_root.sh: --src is required" >&2; exit 2; }

patch="$(cd "$(dirname "$0")" && pwd)/wpe_root.patch"
if ! git -C "$src" apply --reverse --check "$patch" 2>/dev/null; then
  git -C "$src" apply "$patch"
fi
grep -q 'WEBSPACE_WPE_ROOT' "$src/Source/WebKit/Shared/glib/ProcessExecutablePathGLib.cpp" \
  || { echo "wpe_root.sh: $patch did not reach the helper processes' lookup" >&2; exit 1; }

echo "Source/WebKit/Shared/glib/ProcessExecutablePathGLib.cpp, Source/WebKit/UIProcess/API/glib/WebKitWebContext.cpp and Source/WTF/wtf/glib/GResources.cpp look for the paths WebKit was configured with under the directory WEBSPACE_WPE_ROOT names, where it is set, by linux/wpe_root.patch (wpe_root.patch beside this file)"
