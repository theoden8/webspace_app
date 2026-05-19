#!/usr/bin/env bash
# Build the webspace_adblock Rust library for the requested target and
# place the artifact where each platform's loader / build system expects.
#
# Usage:
#   scripts/build_rust.sh linux          # native Linux .so → linux/lib/
#   scripts/build_rust.sh android <abi>  # Android .so → android/app/src/main/jniLibs/<abi>/
#                                          (abi ∈ arm64-v8a|armeabi-v7a|x86_64|x86)
#   scripts/build_rust.sh android-all    # all four Android ABIs
#   scripts/build_rust.sh ios            # iOS device + simulator XCFramework → ios/Frameworks/
#   scripts/build_rust.sh macos          # universal dylib → macos/Frameworks/
#
# Requires: rustc, cargo, cbindgen (for header). Android additionally
# needs cargo-ndk + ANDROID_NDK_HOME set. iOS/macOS need an Apple host.
#
# AdblockEngine.load() returns null when the library is missing, so a
# failure to build for some target is non-fatal for the app — the
# legacy Dart engine remains the fallback. CI is permitted to mark
# the Rust build "warning" instead of "error" on platforms that
# aren't ready yet.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/rust/webspace_adblock"
# Resolve our own path BEFORE the `cd` below — recursive self-invocation
# (the android-all loop) uses this. `$0` alone breaks when the caller
# passed a relative path: Gradle's Exec task runs us as
# `bash scripts/build_rust.sh android-all` from the repo root, then we
# cd into rust/webspace_adblock/ where `scripts/build_rust.sh` no longer
# exists.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

cd "$CRATE_DIR"

usage() {
  sed -n '2,18p' "$SELF" >&2
  exit 64
}

case "${1:-}" in
  linux)
    cargo build --release --locked
    mkdir -p "$REPO_ROOT/linux/lib"
    cp target/release/libwebspace_adblock.so "$REPO_ROOT/linux/lib/"
    echo "Built: linux/lib/libwebspace_adblock.so"
    ;;

  android)
    abi="${2:-}"
    [ -z "$abi" ] && usage
    case "$abi" in
      arm64-v8a)     target="aarch64-linux-android" ;;
      armeabi-v7a)   target="armv7-linux-androideabi" ;;
      x86_64)        target="x86_64-linux-android" ;;
      x86)           target="i686-linux-android" ;;
      *) echo "Unknown abi: $abi" >&2; exit 64 ;;
    esac
    rustup target add "$target" 2>/dev/null || true
    # cargo-ndk drives the NDK toolchains so we don't have to thread
    # CC_/AR_/CARGO_TARGET_*_LINKER ourselves.
    cargo ndk --target "$abi" --platform 21 -- build --release --locked
    out_dir="$REPO_ROOT/android/app/src/main/jniLibs/$abi"
    mkdir -p "$out_dir"
    cp "target/$target/release/libwebspace_adblock.so" "$out_dir/"
    echo "Built: android/app/src/main/jniLibs/$abi/libwebspace_adblock.so"
    ;;

  android-all)
    for abi in arm64-v8a armeabi-v7a x86_64 x86; do
      "$SELF" android "$abi"
    done
    ;;

  ios)
    # Output static `.a` files stamped by Xcode's $(PLATFORM_NAME).
    # The Pod hook uses `-force_load $(SRCROOT)/Frameworks/libwebspace_
    # adblock-$(PLATFORM_NAME).a` so the linker keeps every FFI
    # symbol in the .app binary (otherwise dead-stripped — Dart FFI
    # has no compile-time references to surface them). Dropping the
    # XCFramework wrapper because Xcode's xcframework processing
    # doesn't play nicely with -force_load (path-to-slice isn't a
    # stable Xcode variable).
    # LTO off for Apple targets: `lto = true` in Cargo.toml makes rustc
    # emit LLVM bitcode .o files (deferred to ld for the final codegen).
    # If the Rust toolchain's LLVM is newer than Xcode's, ld/nm reject
    # the bitcode with "Unknown attribute kind (NNN)" — the .a links as
    # if empty, no ws_* symbols survive into Runner, ContentBlocker
    # silently falls back to the Dart parser. Native-code emission via
    # lto=false sidesteps the LLVM version skew at the cost of cross-
    # crate inlining, which is fine for a one-FFI-call-per-request hot
    # path. Other platforms keep full LTO.
    for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
      rustup target add "$target" 2>/dev/null || true
      CARGO_PROFILE_RELEASE_LTO=false \
        cargo build --release --locked --target "$target"
    done
    out_dir="$REPO_ROOT/ios/Frameworks"
    mkdir -p "$out_dir"
    # Device: single arch arm64.
    cp "target/aarch64-apple-ios/release/libwebspace_adblock.a" \
      "$out_dir/libwebspace_adblock-iphoneos.a"
    # Simulator: arm64 (M-series Mac) + x86_64 (Intel Mac) combined.
    lipo -create \
      "target/aarch64-apple-ios-sim/release/libwebspace_adblock.a" \
      "target/x86_64-apple-ios/release/libwebspace_adblock.a" \
      -output "$out_dir/libwebspace_adblock-iphonesimulator.a"
    echo "Built: ios/Frameworks/libwebspace_adblock-iphoneos.a"
    echo "Built: ios/Frameworks/libwebspace_adblock-iphonesimulator.a"
    ;;

  macos)
    # Same pattern as iOS: universal static `.a`, force-loaded by
    # the Pod hook so DynamicLibrary.process() can resolve symbols.
    # macOS doesn't split device/simulator slices — one fat `.a`
    # covering both arm64 and x86_64 hosts is enough.
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
      rustup target add "$target" 2>/dev/null || true
      CARGO_PROFILE_RELEASE_LTO=false \
        cargo build --release --locked --target "$target"
    done
    out_dir="$REPO_ROOT/macos/Frameworks"
    mkdir -p "$out_dir"
    lipo -create \
      "target/aarch64-apple-darwin/release/libwebspace_adblock.a" \
      "target/x86_64-apple-darwin/release/libwebspace_adblock.a" \
      -output "$out_dir/libwebspace_adblock.a"
    echo "Built: macos/Frameworks/libwebspace_adblock.a"
    ;;

  header)
    # Regenerate the C header. Only needed when changing the FFI
    # surface; the generated header is committed.
    if ! command -v cbindgen >/dev/null 2>&1; then
      cargo install --locked cbindgen
    fi
    cbindgen --config cbindgen.toml \
      --crate webspace_adblock \
      --output "$REPO_ROOT/rust/include/webspace_adblock.h"
    echo "Regenerated: rust/include/webspace_adblock.h"
    ;;

  *)
    usage
    ;;
esac
