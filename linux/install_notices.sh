#!/usr/bin/env bash
# Writes the notices of a library the Linux packages build from source and
# bundle (LICENSE-003), the way a Debian package carries its own: <dest>/copyright
# in the machine-readable format (DEP-5), naming the source it was built from and
# its licence, and <dest>/licences/ holding every licence file of that source
# tree. The app's licences page shows each such file (bundled_notices_io.dart).
#
# With --third-party, the tree's third-party directories are first held to an
# audited table (path, licence, whether the build compiles it in): a directory
# the table does not list fails the build, and the licence files of one it marks
# `no` are left out, since nothing of it ships.
#
#   install_notices.sh --src DIR --dest DIR --name NAME --source URL \
#     --revision REV --license 'LGPL-2.1+ and BSD-2-clause' \
#     [--third-party TABLE] [--offer]
set -euo pipefail

src='' dest='' name='' source='' revision='' license='' table='' offer=no
while [ $# -gt 0 ]; do
  case "$1" in
    --src) src=$2; shift 2 ;;
    --dest) dest=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --revision) revision=$2; shift 2 ;;
    --license) license=$2; shift 2 ;;
    --third-party) table=$2; shift 2 ;;
    --offer) offer=yes; shift ;;
    *) echo "install_notices.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
for pair in "src:$src" "dest:$dest" "name:$name" "source:$source" \
  "revision:$revision" "license:$license"; do
  [ -n "${pair#*:}" ] || { echo "install_notices.sh: --${pair%%:*} is required" >&2; exit 2; }
done
# An offer must name what an archive keeps (LICENSE-004): a branch or tag moves.
if [ "$offer" = yes ] && ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "install_notices.sh: --offer needs --revision to be a commit; got $revision" >&2
  exit 2
fi

skipped=''
if [ -n "$table" ]; then
  rows=$(grep -v '^#' "$table" | grep -v '^$')
  listed=$(printf '%s\n' "$rows" | cut -f1 | awk -F/ 'NF == 3' | sort)
  found=$(cd "$src" && find Source/ThirdParty -mindepth 1 -maxdepth 1 -type d | sort)
  if [ "$listed" != "$found" ]; then
    echo "install_notices.sh: $src's Source/ThirdParty does not match $table; read each new directory's licence into the table:" >&2
    diff <(printf '%s\n' "$listed") <(printf '%s\n' "$found") >&2 || true
    exit 1
  fi
  skipped=$(printf '%s\n' "$rows" | awk -F'\t' '$3 == "no" { print $1 }')
fi

# The tree's files, relative to it, less tests and what the table marks `no`.
tree_files() {
  (cd "$src" && find . \
    \( -name .git -o -name LayoutTests -o -name JSTests -o -name ManualTests \
       -o -iname test -o -iname tests -o -iname testing \) -prune -o -type f -print) \
    | sed 's|^\./||' | LC_ALL=C sort \
    | awk -v skips="$skipped" 'BEGIN { n = split(skips, skip, "\n") }
        { for (i = 1; i <= n; i++) if (skip[i] != "" && index($0, skip[i] "/") == 1) next; print }'
}
files=$(tree_files)

mkdir -p "$dest/licences"
count=0
while IFS= read -r rel; do
  install -D -m 644 "$src/$rel" "$dest/licences/$rel"
  count=$((count + 1))
done < <(printf '%s\n' "$files" | grep -i -E '(^|/)(licen[cs]e|copying|notice)[^/]*$')
[ "$count" -gt 0 ] || { echo "install_notices.sh: no licence file under $src" >&2; exit 1; }

# Most of a tree names its copyright holders in each file's header, not in a
# licence file, and the licences ask for those notices to travel with the
# binary too.
{ printf '%s\n' "$files" | grep -E '\.(c|cc|cpp|h|hpp|mm|js|mjs|css|py|rs)$' || true; } \
  | (cd "$src" && tr '\n' '\0' | xargs -0 -r grep -h -i -o -E 'copyright (\(c\) |© *)?[0-9]{4}[^*"]*' || true) \
  | sed -E 's/[[:space:]]+$//' | LC_ALL=C sort -u > "$dest/licences/COPYRIGHT-HOLDERS.txt"

{
  echo 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/'
  echo "Upstream-Name: $name"
  echo "Source: $source"
  echo "Comment: Built as it is from $source at $revision."
  echo " The licence files of that source tree are in licences/ beside this file."
  if [ "$offer" = yes ]; then
    echo ' .'
    echo " For at least three years from the day you received this copy, the"
    echo " maintainers of Webspace will give anyone who asks a complete"
    echo " machine-readable copy of that source, for no more than the cost of"
    echo " making the copy: ask at https://github.com/theoden8/webspace_app/issues."
  fi
  echo
  echo 'Files: *'
  echo "Copyright: the $name authors; see licences/"
  echo "License: $license"
} > "$dest/copyright"
echo "install_notices.sh: $name, $count licence files, in $dest"
