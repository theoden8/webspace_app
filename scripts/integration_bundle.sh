#!/usr/bin/env bash
# One app build for every integration_test file a desktop tier runs.
#
# `flutter test -d <desktop>` builds the app for each file it is given, and
# so does `flutter drive`: it still declares `--no-build`, but Flutter 3.44.9
# never reads the flag. `--use-application-binary` is what skips the build,
# and a prebuilt app runs the entrypoint it was built with. So a tier builds
# one entrypoint that holds every file, and each launch picks its file from
# WEBSPACE_INTEGRATION_FILE. Each file still gets an app process of its own.
#
#   integration_bundle.sh build <device> <integration_test/x_test.dart>...
#       writes the entrypoint, builds it, and records the app for `run`
#   integration_bundle.sh run <device> <integration_test/x_test.dart> <log>
#       runs that file in an app process of its own, its output also in <log>:
#       the recorded app through `flutter drive`, or that file's own
#       `flutter test` when no app is recorded
#
# A build that fails records no app, so one file that does not compile costs
# only itself. An app that does not launch is forgotten, and that file and
# every one after it run their own `flutter test`.
#
# --no-pub everywhere: the job resolved its packages already, and a resolve
# asks pub.dev for advisories, which the Linux egress guard blocks (exit 69).
set -eo pipefail

dir=build/integration_bundle
entry=$dir/main.dart
record=$dir/app

# What `flutter test` and the build take on <device> beyond the file.
device_flags() {
  case "$1" in
    # The sandbox off, as the macOS tier has always run: CI has no signing
    # identity, and a sandboxed debug app keeps its VM service from the tool.
    macos) echo --ci ;;
    linux) ;;
  esac
}

# The app a debug build for <device> leaves, or nothing.
built_app() {
  case "$1" in
    macos) set -- build/macos/Build/Products/Debug/*.app ;;
    linux)
      name="$(sed -n 's/^set(BINARY_NAME "\(.*\)")$/\1/p' linux/CMakeLists.txt)"
      set -- build/linux/*/debug/bundle/"$name"
      ;;
  esac
  if [ -e "$1" ]; then echo "$1"; fi
}

usage() {
  echo "usage: $0 build <device> <file>... | run <device> <file> <log>" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
command="$1"; device="$2"; shift 2
case "$device" in macos|linux) ;; *) echo "unknown device: $device" >&2; exit 2 ;; esac

case "$command" in
  build)
    for f in "$@"; do
      case "$f" in
        integration_test/*_test.dart) [ -f "$f" ] || { echo "build: $f does not exist" >&2; exit 2; } ;;
        *) echo "build: $f is not an integration_test/*_test.dart file" >&2; exit 2 ;;
      esac
    done
    mkdir -p "$dir"
    rm -f "$record"
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
    # shellcheck disable=SC2046 # device_flags is zero or one word
    if fvm flutter build "$device" --debug --no-pub $(device_flags "$device") \
        -t "$entry" > "$dir/build.log" 2>&1; then
      app="$(built_app "$device")"
      if [ -n "$app" ]; then echo "$app" > "$record"; fi
    fi
    tail -20 "$dir/build.log"
    if [ -f "$record" ]; then
      echo "integration bundle: $(cat "$record") runs $# files"
    else
      echo "::warning::the integration bundle did not build; each file runs its own flutter test"
    fi
    ;;
  run)
    [ "$#" -eq 2 ] || usage
    file="$1"; log="$2"
    if [ -f "$record" ]; then
      rc=0
      WEBSPACE_INTEGRATION_FILE="$(basename "$file")" fvm flutter drive --no-pub \
        --driver=test_driver/plain_driver.dart --target="$entry" \
        --use-application-binary="$(cat "$record")" -d "$device" 2>&1 \
        | tee "$log" || rc=$?
      [ "$rc" -eq 0 ] && exit 0
      # Once the driver reaches the app the outcome is the file, pass or
      # fail. Before that it is the app, and would be every file.
      if grep -q 'VMServiceFlutterDriver: Connecting' "$log"; then exit "$rc"; fi
      echo "::warning::the integration bundle did not launch for $file; it and every file after it run their own flutter test"
      rm -f "$record"
    fi
    # shellcheck disable=SC2046 # device_flags is zero or one word
    fvm flutter test --no-pub "$file" -d "$device" $(device_flags "$device") 2>&1 \
      | tee "$log"
    ;;
  *) usage ;;
esac
