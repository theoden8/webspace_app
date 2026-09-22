#!/usr/bin/env bash
# Prints which System WebView the device is actually running.
#
# Two emulator tiers depend on what that WebView supports -- the proxy router
# needs MULTI_PROFILE, and the settings seam's containerId comparison only
# happens where the app binds a container -- so a reader has to be able to
# tell "the gate passed" from "the gate never ran" (BUG-014 caution 8).
#
# Dumping a fixed package name does not answer it. `com.google.android.webview`
# is the provider on google_apis images; the api-35 `default` image this
# workflow pins serves `com.android.webview`, so that grep matched nothing and
# every run of this tier printed "(version not reported)" -- an instrument that
# reported nothing, in the tier that exists to avoid exactly that.
# `dumpsys webviewupdate` names the CURRENT provider and its version, whichever
# package that is.
set -euo pipefail

device_id="${1:?usage: print_android_webview_version.sh <device-id>}"

echo "── System WebView on device ──"

if adb -s "$device_id" shell dumpsys webviewupdate 2>/dev/null \
    | grep -m1 -i 'current webview package'; then
  exit 0
fi

# Fallback for a device whose WebViewUpdateService dump is shaped differently.
for pkg in com.android.webview com.google.android.webview com.android.chrome; do
  if adb -s "$device_id" shell dumpsys package "$pkg" 2>/dev/null \
      | grep -m1 versionName; then
    echo "  (provider: $pkg)"
    exit 0
  fi
done

echo "  (version not reported)"
