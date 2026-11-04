#!/usr/bin/env bash
# Asserts, from a built Linux package's files, that WebKit is a shared library
# of its own that a library of the app's loads at run time, so a user can
# replace it (LICENSE-004), and that every copy carries the PDF.js fonts of the
# OFL release linux/pdfjs_fonts.sh put there, not WebKit's GPL-2.0 ones
# (LICENSE-001; WebKit stores a .ttf uncompressed); and that libwpe, whose
# src/key-unicode.c is under the LGPL, is a shared library of its own too. The
# snap and the flatpak both run it.
#
#   verify_webkit_shipped.sh <package root> <app directory under it>
set -euo pipefail

root="${1:?usage: verify_webkit_shipped.sh <package root> <app directory under it>}"
app="${2:?usage: verify_webkit_shipped.sh <package root> <app directory under it>}"

mapfile -t libraries < <(find "$root" -name 'libWPEWebKit-2.0.so.*' -type f | sort)
[ "${#libraries[@]}" -gt 0 ] \
  || { echo "::error::$root carries no libWPEWebKit-2.0.so of its own" >&2; exit 1; }
for webkit in "${libraries[@]}"; do
  LC_ALL=C grep -a -q 'Licensed under the SIL Open Font License' "$webkit" \
    || { echo "::error::$webkit carries no PDF.js font of the OFL release" >&2; exit 1; }
  if LC_ALL=C grep -a -q 'Liberation Fonts license' "$webkit"; then
    echo "::error::$webkit carries Liberation 1.x, under GPL-2.0" >&2
    exit 1
  fi
done

loads=()
for f in "$root/$app"/webspace_app "$root/$app"/lib/*.so; do
  [ -f "$f" ] || continue
  needed="$(readelf -d "$f")"
  grep -q '(NEEDED).*\[libWPEWebKit-2\.0\.so' <<<"$needed" && loads+=("${f#"$root"/}")
done
[ "${#loads[@]}" -gt 0 ] \
  || { echo "::error::nothing in $root/$app loads WebKit as a shared library" >&2; exit 1; }
echo "WebKit (${libraries[*]#"$root"/}) is a shared library of its own, loaded by ${loads[*]}"

mapfile -t wpe < <(find "$root" -name 'libwpe-1.0.so.*' -type f | sort)
[ "${#wpe[@]}" -gt 0 ] \
  || { echo "::error::$root carries no libwpe-1.0.so of its own" >&2; exit 1; }
wpe_loads=()
for f in "${libraries[@]}" "$root/$app"/webspace_app "$root/$app"/lib/*.so; do
  [ -f "$f" ] || continue
  grep -q '(NEEDED).*\[libwpe-1\.0\.so' <<<"$(readelf -d "$f")" && wpe_loads+=("${f#"$root"/}")
done
[ "${#wpe_loads[@]}" -gt 0 ] \
  || { echo "::error::nothing in $root loads libwpe as a shared library" >&2; exit 1; }
echo "libwpe (${wpe[*]#"$root"/}) is a shared library of its own, loaded by ${wpe_loads[*]}"
