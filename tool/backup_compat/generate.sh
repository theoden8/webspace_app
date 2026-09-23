#!/usr/bin/env bash
# Write test/fixtures/backup_compat/<tag>/ by running each release's own
# serializers over superset.json, so a fixture is what that release really
# exported rather than what someone remembers it exporting.
#
#   tool/backup_compat/generate.sh              every tag that has a backup format
#   tool/backup_compat/generate.sh v0.3.1 v0.3.2
#   tool/backup_compat/generate.sh HEAD         the committed tree, named after
#                                               pubspec.yaml's version (release day)
#
# Needs network for `pub get` in each old tree, and node for prefs_keys.js.
# FLUTTER overrides the `fvm flutter` default; WORK_DIR keeps the worktrees
# somewhere specific.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
here="$repo/tool/backup_compat"
out_root="$repo/test/fixtures/backup_compat"
read -r -a flutter <<< "${FLUTTER:-fvm flutter}"
work="${WORK_DIR:-$(mktemp -d)}"

if [ "$#" -eq 0 ]; then
  refs=()
  while read -r tag; do
    git -C "$repo" cat-file -e "$tag:lib/services/settings_backup.dart" 2>/dev/null \
      && refs+=("$tag")
  done < <(git -C "$repo" tag --list 'v*' --sort=v:refname)
else
  refs=("$@")
fi

feature() {
  local wt="$1" name="$2" on="$3"
  if [ "$on" = 1 ]; then
    cp "$here/features/$name.dart" "$wt/test/backup_compat_gen/features/"
  else
    cp "$here/features_off/$name.dart" "$wt/test/backup_compat_gen/features/"
  fi
}

has() { grep -q "$2" "$1" 2>/dev/null && echo 1 || echo 0; }

for ref in "${refs[@]}"; do
  if [[ "$ref" == v* ]]; then
    name="$ref"
  else
    version="$(git -C "$repo" show "$ref:pubspec.yaml" | sed -n 's/^version: *\([^+ ]*\).*/\1/p')"
    name="v$version"
  fi
  wt="$work/$name"
  echo "== $ref -> $name"
  rm -rf "$wt"
  git -C "$repo" worktree add --force --detach "$wt" "$ref" >/dev/null

  mkdir -p "$wt/test/backup_compat_gen/features"
  cp "$here/generator_test.dart" "$wt/test/backup_compat_gen/"
  feature "$wt" registry "$(has "$wt/lib/settings/app_prefs.dart" readExportedAppPrefs)"
  feature "$wt" theme "$(has "$wt/lib/main.dart" toStorageIndex)"
  feature "$wt" scripts "$(has "$wt/lib/settings/user_script.dart" 'class UserScriptConfig')"
  feature "$wt" qr "$(has "$wt/lib/services/site_settings_qr_codec.dart" shareableSubset)"
  feature "$wt" links "$(has "$wt/lib/services/link_routing_service.dart" parseWebspaceUri)"

  staging="$work/out-$name"
  rm -rf "$staging"
  (
    cd "$wt"
    "${flutter[@]}" pub get >/dev/null
    "${flutter[@]}" test test/backup_compat_gen/generator_test.dart \
      --dart-define=BACKUP_COMPAT_OUT="$staging" \
      --dart-define=BACKUP_COMPAT_SUPERSET="$here/superset.json"
  )
  node "$here/prefs_keys.js" "$wt/lib" > "$staging/prefs_writes.json"
  rm -rf "${out_root:?}/$name"
  mkdir -p "$out_root"
  mv "$staging" "$out_root/$name"
  git -C "$repo" worktree remove --force "$wt"
done
