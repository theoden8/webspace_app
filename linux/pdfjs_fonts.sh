#!/usr/bin/env bash
# Replaces the Liberation Sans fonts PDF.js ships inside WebKit's tree,
# release 1.07.4 under GPL-2.0 with a font exception, by a 2.x release under
# the SIL Open Font License, before WebKit compiles them into its library
# (LICENSE-001). 2.x keeps the metrics PDF.js's own width tables assume, and
# the file names stay, so PdfJSFiles.cmake and PDF.js's font map read the same
# files. Fails when the replacement is not a 2.x release under the OFL, or
# when any file under PDF.js still carries a GNU licence. Prints what it
# changed, for the copyright file linux/install_notices.sh writes.
#
#   pdfjs_fonts.sh --src WEBKIT_TREE --fonts DIR_OF_LiberationSans-*.ttf \
#     (--copyright THEIR_DEP5_COPYRIGHT_FILE | --licence THEIR_LICENCE_FILE)
#
# --copyright reads the fonts' copyright lines and licence from a Debian
# copyright file; --licence takes a file that holds both as it is, as the
# freedesktop SDK installs the fonts' LICENSE.
set -euo pipefail

src='' fonts='' copyright='' licence=''
while [ $# -gt 0 ]; do
  case "$1" in
    --src) src=$2; shift 2 ;;
    --fonts) fonts=$2; shift 2 ;;
    --copyright) copyright=$2; shift 2 ;;
    --licence) licence=$2; shift 2 ;;
    *) echo "pdfjs_fonts.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
for pair in "src:$src" "fonts:$fonts"; do
  [ -n "${pair#*:}" ] || { echo "pdfjs_fonts.sh: --${pair%%:*} is required" >&2; exit 2; }
done
if { [ -n "$copyright" ] && [ -n "$licence" ]; } || { [ -z "$copyright" ] && [ -z "$licence" ]; }; then
  echo "pdfjs_fonts.sh: give one of --copyright and --licence" >&2; exit 2
fi

fail() { echo "pdfjs_fonts.sh: $1" >&2; exit 1; }

pdfjs="$src/Source/ThirdParty/pdfjs"
dir="$pdfjs/web/standard_fonts"
[ -d "$dir" ] || fail "$dir is not there; PDF.js moved its fonts"

version=''
for style in Regular Bold Italic BoldItalic; do
  name="LiberationSans-$style.ttf"
  from="$fonts/$name"
  [ -f "$dir/$name" ] || fail "PDF.js no longer ships $name; read its font map again"
  [ -f "$from" ] || fail "no $from"
  v="$(LC_ALL=C grep -a -o -m1 'Version [0-9][0-9.]*' "$from" | head -1)"
  case "$v" in
    "Version 2."*) ;;
    *) fail "$from is ${v:-of no version}, not a 2.x release" ;;
  esac
  LC_ALL=C grep -a -q 'Licensed under the SIL Open Font License' "$from" \
    || fail "$from does not say it is under the SIL Open Font License"
  install -m 644 "$from" "$dir/$name"
  version="${v#Version }"
done

# The fonts' copyright lines and licence: from the DEP-5 stanza that names
# the OFL for them, or the licence file as it is.
if [ -n "$licence" ]; then
  install -m 644 "$licence" "$dir/LICENSE_LIBERATION"
else
awk '
  /^Files:/ { files = 1; holders = ""; next }
  files && /^Copyright:/ { sub(/^Copyright:[ \t]*/, ""); if ($0 != "") holders = $0 "\n"; grab = 1; next }
  grab && /^ / && !/^License:/ { sub(/^ /, ""); holders = holders $0 "\n"; next }
  grab { grab = 0 }
  /^License: SIL-OFL-1\.1$/ && holders != "" { printf "%s\n", holders; text = 1; next }
  text && /^ / { sub(/^ /, ""); if ($0 == ".") $0 = ""; print; next }
  text { exit }
' "$copyright" > "$dir/LICENSE_LIBERATION"
fi
grep -q 'SIL OPEN FONT LICENSE Version 1.1' "$dir/LICENSE_LIBERATION" \
  || fail "${copyright:-$licence} gave no SIL Open Font License text for the fonts"

if left="$(grep -rIl -i 'general public license' "$pdfjs")"; then
  fail "a GNU licence is still under PDF.js: $left"
fi

echo "Source/ThirdParty/pdfjs/web/standard_fonts/LiberationSans-*.ttf and LICENSE_LIBERATION replaced by Liberation Sans $version (OFL-1.1) by linux/pdfjs_fonts.sh"
