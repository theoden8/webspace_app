#!/usr/bin/env bash
# Assert the Rust adblock engine actually shipped inside the built app
# bundle. The build is graceful-fallback by design (a Rust-less build
# succeeds and the app uses the Dart parser at runtime), so the build
# itself never fails on a missing engine -- this check is what guarantees a
# real CI artifact carries the native engine. Run it at the end of each
# platform's build step.
#
# iOS/macOS/Linux expose the Dart-FFI C ABI (ws_* symbols); Android links
# the engine over JNI (Java_* symbols) and ships it as a packaged .so, so
# its "shipped" proof is .so presence in the APK, not a ws_* nm scan. The
# Kotlin side of the JNI bridge is covered separately by check_jni_intact.sh.
set -euo pipefail

platform="${1:?usage: verify_adblock_shipped.sh <ios|macos|linux|android>}"
min_syms=15

first_match() {
  local g
  for g in "$@"; do
    [ -f "$g" ] && { printf '%s\n' "$g"; return 0; }
  done
  return 1
}

check_ffi_exports() {
  # $1 = mach-o|elf, rest = candidate paths
  local fmt="$1"; shift
  local bin pat
  if ! bin=$(first_match "$@"); then
    echo "::error::$platform webspace_adblock artifact not found (looked: $*)" >&2
    return 1
  fi
  local nm_out
  if [ "$fmt" = mach-o ]; then
    nm_out=$(nm -gU "$bin" 2>/dev/null || true); pat=' T _ws_'
  else
    nm_out=$(nm -D --defined-only "$bin" 2>/dev/null || true); pat=' T ws_'
  fi
  local syms
  syms=$(printf '%s\n' "$nm_out" | grep -c "$pat" || true)
  if [ "$syms" -lt "$min_syms" ]; then
    echo "::error::$platform: expected >=$min_syms ws_* exports in $bin, found $syms" >&2
    printf '%s\n' "$nm_out" | grep 'ws_' || true
    return 1
  fi
  echo "OK: $platform webspace_adblock exports $syms ws_* symbols ($bin)"
}

case "$platform" in
  ios)
    check_ffi_exports mach-o \
      build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/Frameworks/webspace_adblock.framework/webspace_adblock
    ;;
  macos)
    check_ffi_exports mach-o \
      build/macos/Build/Products/Release/*.app/Contents/Frameworks/webspace_adblock.framework/webspace_adblock
    ;;
  linux)
    check_ffi_exports elf \
      build/linux/*/release/bundle/lib/libwebspace_adblock.so
    ;;
  android)
    shopt -s nullglob
    apks=( build/app/outputs/flutter-apk/*-fdroid-release.apk )
    [ ${#apks[@]} -gt 0 ] || { echo "::error::android: no fdroid APK to scan" >&2; exit 1; }
    for apk in "${apks[@]}"; do
      if ! unzip -l "$apk" | grep -qE 'lib/[^/]+/libwebspace_adblock\.so'; then
        echo "::error::android: libwebspace_adblock.so missing from $apk" >&2
        unzip -l "$apk" | grep -E 'lib/' | head || true
        exit 1
      fi
      echo "OK: android $apk ships libwebspace_adblock.so"
    done
    ;;
  *)
    echo "::error::unknown platform '$platform'" >&2; exit 2 ;;
esac
