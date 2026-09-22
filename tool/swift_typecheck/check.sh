#!/usr/bin/env bash
# Type-check ios/Runner/TorControllerPlugin.swift without Xcode.
#
# The plugin is the one file in this repo that no test tier compiles: the
# Dart tiers mock it away and CI builds it only on the Apple job. Two
# compile errors reached a device build before this existed. It type-checks
# against hand-transcribed stub modules (stub_*.swift), so it catches wrong
# selectors, wrong argument labels and type errors -- not behaviour, and
# nothing a stub gets wrong.
#
# Needs any Swift 5 toolchain. Skips (0) when none is installed.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$root/tool/swift_typecheck"
swiftc="${SWIFTC:-$(command -v swiftc || true)}"
if [ -z "$swiftc" ]; then
  echo "swift_typecheck: no swiftc on PATH, skipping"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

modules="Flutter Tor IPtProxy"
# The macos/Runner stubs are Linux-only. On macOS the real Cocoa, WebKit and
# Network frameworks are present, so stub modules under those names are at
# best ambiguous against them -- and the Xcode build compiles that Runner
# file for real later in the same job, so checking it here buys nothing.
# Elsewhere there is no SDK at all, and this is the only gate it gets.
if [ "$(uname -s)" != "Darwin" ]; then
  # Network before WebKit: the WebKit stub types proxyConfigurations in
  # Network's terms, exactly as the SDK has it.
  modules="$modules Cocoa FlutterMacOS Network WebKit"
fi

for module in $modules; do
  "$swiftc" -emit-module -module-name "$module" -swift-version 5 -I "$work" \
    -emit-module-path "$work/$module.swiftmodule" "$here/stub_$module.swift"
done

# canImport(FlutterMacOS) is false against the stubs, which selects the iOS
# branch; the macOS Runner compiles the same file with the other import.
sed 's/#if canImport(FlutterMacOS)/#if false/' \
  "$root/ios/Runner/TorControllerPlugin.swift" > "$work/plugin.swift"

"$swiftc" -typecheck -swift-version 5 -I "$work" "$work/plugin.swift"
echo "swift_typecheck: TorControllerPlugin.swift type-checks"

