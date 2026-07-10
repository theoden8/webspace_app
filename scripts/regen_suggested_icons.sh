#!/usr/bin/env bash
# Regenerate committed icons for the curated suggested sites.
#
# DEVELOPER-RUN ONLY. This is NOT part of the Flutter/Gradle build: it
# contacts third parties (favicon services) and its output is committed.
# Committing the output keeps the build reproducible and free of any
# third-party network contact (F-Droid reproducible builds).
#
# Usage:
#   scripts/regen_suggested_icons.sh
#
# After running:
#   1. Review the new PNGs under assets/suggested_icons/.
#   2. Ensure pubspec.yaml registers the assets/suggested_icons/ directory
#      (only once at least one asset exists, or Flutter's build fails on an
#      empty asset dir).
#   3. Run: fvm flutter test test/suggestion_icons_offline_test.dart
#
# Note: bundling third-party (possibly trademarked) logos has licensing
# implications F-Droid may flag. The offline list renders a monogram for any
# host NOT listed in kBundledIconHosts, so leaving a host out is safe.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/assets/suggested_icons"
service="$repo_root/lib/services/suggested_sites_service.dart"
bundled="$repo_root/lib/services/bundled_icons.dart"
size=128

mkdir -p "$out_dir"

# Parse `domain: '<host>'` entries from the single source of truth.
mapfile -t hosts < <(grep -oE "domain: '[^']+'" "$service" | sed -E "s/domain: '([^']+)'/\1/" | sort -u)

if [ "${#hosts[@]}" -eq 0 ]; then
  echo "No suggestion domains found in $service" >&2
  exit 1
fi

written=()
for host in "${hosts[@]}"; do
  key="${host#www.}"
  url="https://www.google.com/s2/favicons?domain=${host}&sz=${size}"
  echo "fetch $host -> $key.png"
  if curl -fsSL "$url" -o "$out_dir/$key.png"; then
    written+=("$key")
  else
    echo "  WARN: failed to fetch $host (will render as monogram)" >&2
    rm -f "$out_dir/$key.png"
  fi
done

# Rewrite the kBundledIconHosts const with the hosts we actually wrote.
{
  printf 'const Set<String> kBundledIconHosts = {\n'
  for k in $(printf '%s\n' "${written[@]}" | sort -u); do
    printf "  '%s',\n" "$k"
  done
  printf '};\n'
} > /tmp/_bundled_set.txt

python3 - "$bundled" /tmp/_bundled_set.txt <<'PY'
import re, sys
path, setfile = sys.argv[1], sys.argv[2]
src = open(path).read()
new = open(setfile).read().rstrip('\n')
src = re.sub(r'const Set<String> kBundledIconHosts = \{[^}]*\};', new, src, count=1, flags=re.S)
open(path, 'w').write(src)
PY

echo
echo "Wrote ${#written[@]} icons to $out_dir and updated kBundledIconHosts."
echo "Next: register assets/suggested_icons/ in pubspec.yaml, then run flutter analyze + tests."
