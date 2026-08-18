#!/usr/bin/env bash
# Builds one of the two design web targets. Both outputs are derivatives:
# regenerate them, never commit them.
#
#   scripts/design_web.sh app        -> build/web              (designer environment)
#   scripts/design_web.sh gallery    -> build/design_gallery   (card gallery)

set -euo pipefail
cd "$(dirname "$0")/.."

target="${1:-app}"
# build/web is flutter's own output directory; passing it as --output makes the
# build wipe its own result, so the app target takes the default and only the
# gallery is redirected.
case "$target" in
  app)     entry=lib/design_app/main.dart;     out=build/web;            output=() ;;
  gallery) entry=lib/design_gallery/main.dart; out=build/design_gallery; output=(--output "$out") ;;
  *) echo "usage: $0 [app|gallery]" >&2; exit 2 ;;
esac

if command -v fvm >/dev/null 2>&1; then
  flutter="fvm flutter"
elif command -v flutter >/dev/null 2>&1; then
  flutter="flutter"
else
  echo "no flutter on PATH; see the sandbox bootstrap in CLAUDE.md" >&2
  exit 1
fi

# CanvasKit draws no text at all when fonts.gstatic.com is unreachable, and
# --no-web-resources-cdn is what keeps the engine itself local.
node tool/design_gallery/sync_fonts.js

$flutter build web -t "$entry" "${output[@]}" --no-web-resources-cdn "${@:2}"

echo "$target -> $out (serve it with: npm run design:serve -- --root $out)"
