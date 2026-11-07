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
#     [--third-party TABLE] [--offer] [--changed WHAT] \
#     [--licence-text FILE]... [--notice-of PATH]...
#
# --changed names what the build changed in the tree before compiling it, so
# the copyright file does not claim the source as it is.
#
# An LGPL or Apache-2.0 that --license names travels with its text, as each
# asks, and a build whose licences/ holds no such text fails. A tree that names
# one only in a source file's header carries none, so --licence-text adds the
# build host's copy, which must be the text of a licence --license names, read
# by its heading. A notice that lives only in a source file's header, as an
# X11-style permission notice does, asks to appear in the documentation too:
# --notice-of copies the first block comment of PATH (in the tree) that names a
# copyright, as it is, to licences/<PATH, each / as _>.notice.
set -euo pipefail

src='' dest='' name='' source='' revision='' license='' table='' offer=no changed=''
licence_texts=() notice_of=()
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
    --changed) changed=$2; shift 2 ;;
    --licence-text) licence_texts+=("$2"); shift 2 ;;
    --notice-of) notice_of+=("$2"); shift 2 ;;
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

# The licences whose text the notices must carry. text_of names the one
# [file] is the text of, by its first two lines that are not blank: the GNU
# Lesser GPL (or the Library GPL, as LGPL-2.0 is titled), or Apache-2.0;
# nothing for any other file. names_licence says whether --license names one.
text_of() {
  awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); head[++n] = $0; if (n == 2) exit }
    END {
      if (head[1] ~ /^GNU (LESSER|LIBRARY) GENERAL PUBLIC LICENSE$/) print "LGPL"
      else if (head[1] == "Apache License" && head[2] == "Version 2.0, January 2004") print "Apache-2.0"
    }' "$1"
}
names_licence() {
  case "$1" in
    LGPL) grep -q -E '(^|[^[:alnum:]])LGPL-[0-9]' <<<"$license" ;;
    Apache-2.0) grep -q -E '(^|[^[:alnum:]])Apache-2\.0($|[^[:alnum:].+])' <<<"$license" ;;
  esac
}
for text in ${licence_texts[@]+"${licence_texts[@]}"}; do
  [ -f "$text" ] || { echo "install_notices.sh: --licence-text $text is not a file" >&2; exit 2; }
  of="$(text_of "$text")"
  [ -n "$of" ] || { echo "install_notices.sh: --licence-text $text is the text of neither an LGPL nor Apache-2.0" >&2; exit 2; }
  names_licence "$of" || { echo "install_notices.sh: --licence-text $text is the text of $of, which --license does not name" >&2; exit 2; }
done
for rel in ${notice_of[@]+"${notice_of[@]}"}; do
  case "/$rel/" in
    //*|*/../*) echo "install_notices.sh: --notice-of $rel is not a path inside the tree" >&2; exit 2 ;;
  esac
  [ -f "$src/$rel" ] || { echo "install_notices.sh: --notice-of $rel is not a file of $src" >&2; exit 2; }
done

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

# The tree's files, relative to it, less tests, what the table marks `no`, and
# the build directory flatpak-builder makes inside it.
tree_files() {
  (cd "$src" && find . \
    \( -name .git -o -name LayoutTests -o -name JSTests -o -name ManualTests \
       -o -iname test -o -iname tests -o -iname testing -o -name _flatpak_build \) -prune -o -type f -print) \
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
for text in ${licence_texts[@]+"${licence_texts[@]}"}; do
  to="$dest/licences/$(basename "$text")"
  [ ! -e "$to" ] || { echo "install_notices.sh: --licence-text $text would replace the tree's $to" >&2; exit 1; }
  install -m 644 "$text" "$to"
  count=$((count + 1))
done
for family in LGPL Apache-2.0; do
  names_licence "$family" || continue
  carried=no
  while IFS= read -r -d '' file; do
    if [ "$(text_of "$file")" = "$family" ]; then carried=yes; break; fi
  done < <(find "$dest/licences" -type f -print0)
  [ "$carried" = yes ] || {
    echo "install_notices.sh: --license names $family, and no licence file of $src is its text; give the build host's with --licence-text" >&2
    exit 1
  }
done
for rel in ${notice_of[@]+"${notice_of[@]}"}; do
  to="$dest/licences/${rel//\//_}.notice"
  awk '!open && index($0, "/*") { open = 1; block = "" }
    open { block = block $0 "\n" }
    open && index($0, "*/") { open = 0; if (tolower(block) ~ /copyright/) { printf "%s", block; found = 1; exit } }
    END { exit !found }' "$src/$rel" > "$to" || {
    echo "install_notices.sh: --notice-of $rel has no block comment that names a copyright" >&2
    exit 1
  }
  grep -q -i -E 'permission|licen[cs]e' "$to" || {
    echo "install_notices.sh: the notice in $rel names no licence" >&2
    exit 1
  }
  count=$((count + 1))
done

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
  if [ -n "$changed" ]; then
    echo "Comment: Built from $source at $revision, changed before the build:"
    echo " $changed."
  else
    echo "Comment: Built as it is from $source at $revision."
  fi
  echo " The licence files of that source tree are in licences/ beside this file."
  for text in ${licence_texts[@]+"${licence_texts[@]}"}; do
    echo " licences/$(basename "$text") is the build host's copy of a licence text the tree lacks ($(text_of "$text"))."
  done
  for rel in ${notice_of[@]+"${notice_of[@]}"}; do
    echo " licences/${rel//\//_}.notice is the notice $rel carries in its header."
  done
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
