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
    cargo build --release
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
    cargo ndk --target "$abi" --platform 21 -- build --release
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
    for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
      rustup target add "$target" 2>/dev/null || true
      cargo build --release --target "$target"
    done
    out="$REPO_ROOT/ios/Frameworks/WebspaceAdblock.xcframework"
    rm -rf "$out"
    mkdir -p "$REPO_ROOT/ios/Frameworks"
    # Combine sim arches into a fat lib; device stays single-arch.
    sim_dir="$REPO_ROOT/ios/Frameworks/.sim"
    mkdir -p "$sim_dir"
    lipo -create \
      "target/aarch64-apple-ios-sim/release/libwebspace_adblock.a" \
      "target/x86_64-apple-ios/release/libwebspace_adblock.a" \
      -output "$sim_dir/libwebspace_adblock.a"
    xcodebuild -create-xcframework \
      -library "target/aarch64-apple-ios/release/libwebspace_adblock.a" \
      -headers "$REPO_ROOT/rust/include" \
      -library "$sim_dir/libwebspace_adblock.a" \
      -headers "$REPO_ROOT/rust/include" \
      -output "$out"
    rm -rf "$sim_dir"
    echo "Built: $out"
    ;;

  macos)
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
      rustup target add "$target" 2>/dev/null || true
      cargo build --release --target "$target"
    done
    out_dir="$REPO_ROOT/macos/Frameworks"
    mkdir -p "$out_dir"
    lipo -create \
      "target/aarch64-apple-darwin/release/libwebspace_adblock.dylib" \
      "target/x86_64-apple-darwin/release/libwebspace_adblock.dylib" \
      -output "$out_dir/libwebspace_adblock.dylib"
    echo "Built: $out_dir/libwebspace_adblock.dylib"
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
