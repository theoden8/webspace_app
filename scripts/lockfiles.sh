#!/usr/bin/env bash
# Every lock file the repository commits, as CI resolved it.
#
# Some are written only on one platform: Podfile.lock by the pod install a
# macOS build runs, Gemfile.lock's platforms by a bundle install on the
# runner's own. So each job that can write one hands in what its checkout
# changed, and the lockfiles job of Build and Test lays those over the commit
# and publishes every lock file as the `lockfiles` artifact: unzipped at the
# repository root, it updates them all at once.
#
#   lockfiles.sh changed <dir>          copy each lock file this checkout changed into <dir>
#   lockfiles.sh bundle <runs> <dir>    lay <runs>/<job>/ over the checkout, each job's
#                                       `changed`, and copy every lock file into <dir>
set -euo pipefail

cd "$(dirname "$0")/.."

# A container job runs as another user than the one that owns the checkout,
# and git refuses such a tree unless it is named safe.
git() { command git -c safe.directory="$PWD" "$@"; }

# What a lock file is, by name, and only a committed one: a build clones trees
# of its own (go/iptproxy/build, the Tor sources, node_modules) whose lock
# files are not the repository's.
pathspecs=(':(glob)**/*.lock' ':(glob)**/*-lock.json' ':(glob)**/go.sum' ':(glob)**/lake-manifest.json')

copy() { mkdir -p "$2/$(dirname "$1")" && cp "$1" "$2/$1"; }

job() { local n=${1%/}; n=${n##*/}; echo "${n#lockfiles-}"; }

changed() {
  local out=$1 f
  mkdir -p "$out"
  git diff --name-only -z --diff-filter=M HEAD -- "${pathspecs[@]}" |
    while IFS= read -r -d '' f; do
      copy "$f" "$out"
      echo "$f differs from the commit"
    done
}

bundle() {
  local runs=$1 out=$2 f run first disagree=0 changes=""
  while IFS= read -r f; do
    first=""
    for run in "$runs"/*/; do
      [ -f "$run$f" ] || continue
      if [ -z "$first" ]; then
        first=$run
        cp "$run$f" "$f"
        changes="$changes| \`$f\` | $(job "$run") |"$'\n'
        echo "::notice title=Lock files::$f differs from the commit as $(job "$run") resolved it; the lockfiles artifact carries it"
      elif ! cmp -s "$run$f" "$first$f"; then
        echo "::error title=Lock files::$(job "$first") and $(job "$run") resolved $f differently; the lockfiles artifact carries $(job "$first")'s"
        disagree=1
      fi
    done
  done < <(cd "$runs" 2>/dev/null && find . -mindepth 2 -type f | cut -d/ -f3- | sort -u)

  mkdir -p "$out"
  git ls-files -z -- "${pathspecs[@]}" | while IFS= read -r -d '' f; do copy "$f" "$out"; done

  {
    echo "## Lock files"
    echo
    if [ -z "$changes" ]; then
      echo "Every lock file is as committed."
    else
      echo "The \`lockfiles\` artifact carries every lock file; unzip it at the repository root. These differ from the commit:"
      echo
      echo "| Lock file | Resolved by |"
      echo "|---|---|"
      printf '%s' "$changes"
    fi
  } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  return "$disagree"
}

usage() { sed -n '11,13p' "$0" >&2; exit 2; }

case "${1:-}" in
  changed) [ $# -eq 2 ] || usage; changed "$2" ;;
  bundle) [ $# -eq 3 ] || usage; bundle "$2" "$3" ;;
  *) usage ;;
esac
