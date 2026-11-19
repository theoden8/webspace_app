#!/usr/bin/env bash
# Fetches what packs the AppImage (PLATFORM-013) into DIR, each file checked
# against the SHA-256 linux/appimage/tools.tsv pins; a file already there
# with those bytes is kept, one with others is fetched again, and bytes that
# still differ fail. Prints DIR.
#
#   fetch_tools.sh DIR
set -euo pipefail

dir="${1:?usage: fetch_tools.sh DIR}"
table="$(cd "$(dirname "$0")" && pwd)/tools.tsv"
mkdir -p "$dir"

while IFS=$'\t' read -r name url sum; do
  case "$name" in ''|'#'*) continue ;; esac
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "fetch_tools.sh: $name has no SHA-256 in $table" >&2; exit 1; }
  at="$dir/$name"
  if ! [ -f "$at" ] || ! echo "$sum  $at" | sha256sum --check --status; then
    curl --proto '=https' --tlsv1.2 -fsSL --retry 4 --retry-delay 2 -o "$at.part" "$url"
    if ! echo "$sum  $at.part" | sha256sum --check --status; then
      rm -f "$at.part"
      echo "fetch_tools.sh: $url is not the file $table pins" >&2
      exit 1
    fi
    mv "$at.part" "$at"
  fi
  chmod 755 "$at"
done < "$table"
echo "$dir"
