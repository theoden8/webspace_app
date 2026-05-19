#!/usr/bin/env bash
# Build the webspace_adblock Rust library for the requested target and
# place the artifact where each platform's loader / build system expects.
#
# Usage:
#   scripts/build_rust.sh linux          # native Linux .so → linux/lib/
#   scripts/build_rust.sh android <abi>  # Android .so → android/app/src/main/jniLibs/<abi>/
#                                          (abi ∈ arm64-v8a|armeabi-v7a|x86_64|x86)
#   scripts/build_rust.sh android-all    # all four Android ABIs
#   scripts/build_rust.sh apple          # iOS xcframework + macOS fat .a +
#                                          keep_alive.c → rust/webspace_adblock/cocoapods/
#                                          (consumed by the podspec there)
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

  apple)
    # Build the rust .a for every Apple slice (iOS device, iOS sim arm64
    # + x86_64, macOS arm64 + x86_64), assemble into an .xcframework for
    # iOS and a single fat .a for macOS, drop both into the podspec dir,
    # and regenerate keep_alive.c. The CocoaPods podspec at
    # rust/webspace_adblock/cocoapods/ ships these as a vendored
    # framework / library and compiles keep_alive.c into the Runner-
    # depended pod. CocoaPods handles linking via standard pod machinery —
    # no force_load, no -Wl,-u, no Runner.xcodeproj mutation.
    #
    # LTO off for Apple targets: `lto = true` in Cargo.toml makes rustc
    # emit LLVM bitcode .o files (deferred to ld for the final codegen).
    # If the Rust toolchain's LLVM is newer than Xcode's, ld/nm reject
    # the bitcode with "Unknown attribute kind (NNN)" — the .a links as
    # if empty. Native-code emission via lto=false sidesteps the LLVM
    # version skew at the cost of cross-crate inlining, which is fine
    # for a one-FFI-call-per-request hot path. Other platforms keep
    # full LTO.
    # Force PATH to rustup's bin so we don't accidentally invoke a
    # different cargo/rustc (e.g. /opt/homebrew/bin/cargo from
    # `brew install rust`) that has no iOS targets installed. The
    # observed symptom of using the wrong rust is rustup reporting
    # "target ... is up to date" while cargo build fails with
    # E0463 "can't find crate for `core`" — because the sysroot
    # rustup populated isn't the sysroot cargo searches.
    export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
    if ! command -v rustup >/dev/null 2>&1; then
      echo "error: rustup not found on PATH ($PATH)" >&2
      echo "Install from https://rustup.rs/ — Homebrew's rust package" >&2
      echo "lacks Apple cross-targets." >&2
      exit 1
    fi
    cargo_path="$(command -v cargo)"
    rustup_cargo="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
    if [ "$cargo_path" != "$rustup_cargo" ]; then
      echo "[build_rust.sh apple] WARN: cargo at $cargo_path is not"
      echo "[build_rust.sh apple] WARN: rustup's ($rustup_cargo)."
      echo "[build_rust.sh apple] WARN: iOS targets won't be visible."
    fi

    apple_targets=(
      aarch64-apple-ios
      aarch64-apple-ios-sim
      x86_64-apple-ios
      aarch64-apple-darwin
      x86_64-apple-darwin
    )
    installed=$(rustup target list --installed 2>/dev/null || true)
    for target in "${apple_targets[@]}"; do
      if ! echo "$installed" | grep -qx "$target"; then
        echo "[build_rust.sh apple] installing rust target: $target"
        rustup target add "$target"
      fi
    done
    # Drive cargo through `rustup run` so we're guaranteed to use the
    # toolchain rustup just configured the targets for, even if a
    # different cargo is earlier in PATH. Belt-and-braces with the
    # PATH munging above.
    rustup_toolchain="$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')"
    if [ -z "$rustup_toolchain" ]; then
      echo "error: could not determine rustup active toolchain" >&2
      exit 1
    fi
    for target in "${apple_targets[@]}"; do
      CARGO_PROFILE_RELEASE_LTO=false \
        rustup run "$rustup_toolchain" \
        cargo build --release --locked --target "$target"
    done

    pod_dir="$REPO_ROOT/rust/webspace_adblock/cocoapods"
    mkdir -p "$pod_dir"

    # iOS simulator fat .a: arm64 (M-series host) + x86_64 (Intel host).
    # IMPORTANT: each xcframework slice's static lib must share the same
    # basename across slices, or CocoaPods refuses to install the
    # xcframework ("static libraries with differing binary names").
    # Stage the simulator fat in a dedicated dir under the same name
    # the device slice already uses (libwebspace_adblock.a).
    sim_fat_dir="target/iphonesimulator-fat"
    mkdir -p "$sim_fat_dir"
    lipo -create \
      "target/aarch64-apple-ios-sim/release/libwebspace_adblock.a" \
      "target/x86_64-apple-ios/release/libwebspace_adblock.a" \
      -output "$sim_fat_dir/libwebspace_adblock.a"

    # iOS xcframework wrapping device + simulator slices. CocoaPods picks
    # the correct slice at link time via PLATFORM_NAME; we don't need to
    # bake the path into LDFLAGS like we did with bare -force_load.
    rm -rf "$pod_dir/WebspaceAdblock.xcframework"
    xcodebuild -create-xcframework \
      -library "target/aarch64-apple-ios/release/libwebspace_adblock.a" \
      -library "$sim_fat_dir/libwebspace_adblock.a" \
      -output "$pod_dir/WebspaceAdblock.xcframework" >/dev/null

    # macOS fat .a (arm64 + x86_64).
    lipo -create \
      "target/aarch64-apple-darwin/release/libwebspace_adblock.a" \
      "target/x86_64-apple-darwin/release/libwebspace_adblock.a" \
      -output "$pod_dir/libwebspace_adblock-macos.a"

    # Generate keep_alive.c from the rust source's #[no_mangle] surface.
    # The pod compiles this; its __attribute__((used)) array of FFI
    # addresses forces ld to retain every ws_* symbol against dead_strip
    # — without it dlsym from Dart FFI would find nothing because the
    # linker can't see the runtime lookups.
    syms=$(grep -hE 'pub extern "C" fn (ws_[a-z_]+)' "$CRATE_DIR/src/lib.rs" \
      | sed -E 's/.*pub extern "C" fn (ws_[a-z_]+).*/\1/')
    if [ -z "$syms" ]; then
      echo "error: no ws_* FFI symbols found in src/lib.rs" >&2
      exit 1
    fi
    {
      echo '// SPDX-License-Identifier: MPL-2.0'
      echo '// Auto-generated by scripts/build_rust.sh apple — do not edit.'
      echo '//'
      echo '// Defeats -dead_strip on rust FFI symbols by listing addresses'
      echo '// of every ws_* function in a __used array. Dart FFI looks them'
      echo "// up via dlsym at runtime, invisible to ld, so an explicit"
      echo '// compile-time reference is the only way to keep them.'
      echo ''
      echo '// Each function is forward-declared as a generic int(void) —'
      echo "// the real signatures live in rust/include/webspace_adblock.h."
      echo '// We never call through these prototypes, only take addresses,'
      echo "// so the wrong signatures don't matter."
      for s in $syms; do
        echo "extern int $s(void);"
      done
      echo ''
      echo '__attribute__((used, visibility("default")))'
      echo 'void *const ws_ffi_keep_alive[] = {'
      for s in $syms; do
        echo "    (void *)&$s,"
      done
      echo '};'
    } > "$pod_dir/keep_alive.c"

    echo "Built: rust/webspace_adblock/cocoapods/WebspaceAdblock.xcframework"
    echo "Built: rust/webspace_adblock/cocoapods/libwebspace_adblock-macos.a"
    echo "Built: rust/webspace_adblock/cocoapods/keep_alive.c ($(echo "$syms" | wc -l | tr -d ' ') ws_* symbols)"
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
