#!/usr/bin/env bash
# One app build for every integration_test file a tier runs.
#
# `flutter test -d <desktop>` builds the app for each file it is given, and
# so does `flutter drive`: it still declares `--no-build`, but Flutter 3.44.9
# never reads the flag. `--use-application-binary` is what skips the build,
# and a prebuilt app runs the entrypoint it was built with. So the tier builds
# one entrypoint that holds every file, and each launch picks its file from
# WEBSPACE_INTEGRATION_FILE. Each file still gets an app process of its own.
#
#   integration_bundle.sh entrypoint <integration_test/x_test.dart>...
#       writes the entrypoint (a derivative, under build/) and prints its path
#   integration_bundle.sh drive <device> <app> <integration_test/x_test.dart>
#       launches the prebuilt <app> on <device>, running that file
set -euo pipefail

entry=build/integration_bundle/main.dart

case "${1:-}" in
  entrypoint)
    shift
    [ "$#" -gt 0 ] || { echo "entrypoint: no files" >&2; exit 2; }
    for f in "$@"; do
      case "$f" in
        integration_test/*_test.dart) [ -f "$f" ] || { echo "entrypoint: $f does not exist" >&2; exit 2; } ;;
        *) echo "entrypoint: $f is not an integration_test/*_test.dart file" >&2; exit 2 ;;
      esac
    done
    mkdir -p "$(dirname "$entry")"
    {
      echo "// Written by scripts/integration_bundle.sh."
      echo "import 'dart:io';"
      echo
      for f in "$@"; do
        echo "import '../../$f' as $(basename "$f" .dart);"
      done
      echo
      echo "const _files = <String, void Function()>{"
      for f in "$@"; do
        echo "  '$(basename "$f")': $(basename "$f" .dart).main,"
      done
      echo "};"
      cat <<'EOF'

void main() {
  final name = Platform.environment['WEBSPACE_INTEGRATION_FILE'];
  final run = _files[name];
  if (run == null) {
    stderr.writeln('WEBSPACE_INTEGRATION_FILE=$name names no file in this '
        'build: ${_files.keys.join(' ')}');
    exit(64);
  }
  run();
}
EOF
    } > "$entry"
    echo "$entry"
    ;;
  drive)
    [ "$#" -eq 4 ] || { echo "usage: $0 drive <device> <app> <file>" >&2; exit 2; }
    [ -f "$entry" ] || { echo "drive: no $entry; run entrypoint first" >&2; exit 2; }
    WEBSPACE_INTEGRATION_FILE="$(basename "$4")" exec fvm flutter drive \
      --driver=test_driver/plain_driver.dart --target="$entry" \
      --use-application-binary="$3" -d "$2"
    ;;
  *)
    echo "usage: $0 entrypoint <file>... | drive <device> <app> <file>" >&2
    exit 2
    ;;
esac
