#!/usr/bin/env bash

set -ex

cd "$(dirname "$0")/.."

fvm flutter build apk --flavor fmain --release
fvm flutter build apk --flavor fmain --release --split-per-abi
fvm flutter build appbundle --flavor fmain --release
fvm flutter build ipa --release

# Flutter's Gradle plugin names every APK app[-<abi>]-<flavor>-<mode>.apk
# whatever outputFileName says, so the release names are given here.
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"
APKS=build/app/outputs/flutter-apk
cp "$APKS/app-fmain-release.apk" "$OUT/webspace-universal.apk"
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "$APKS/app-$abi-fmain-release.apk" "$OUT/webspace-$abi.apk"
done
cp build/app/outputs/bundle/fmainRelease/app-fmain-release.aab "$OUT/webspace.aab"
cp build/ios/ipa/*.ipa "$OUT/webspace.ipa"
ls -l "$OUT"
