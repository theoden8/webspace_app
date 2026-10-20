#!/usr/bin/env bash
#
# Restores a formal stage's kept work from the newest artifact a push to
# master uploaded, for a run whose Actions cache is gone. The cache budget is
# shared with the toolchain caches and evicts the least recently used entry,
# so a stage's cache can be gone two hours after master saved it; an artifact
# is not evicted. Only this repository's master runs are taken, as the cache
# would be. Without the API, a token or an artifact, the stage runs cold.
#
#   scripts/restore_formal_artifact.sh <artifact name> <directory>
set -euo pipefail

name="$1"
dest="$2"
# The API names no order, so the page is sorted here; a page of 100 holds every
# artifact a two-week retention keeps unless master took more pushes than that.
newest='[.artifacts[]
  | select(.expired | not)
  | select(.workflow_run.head_branch == "master")
  | select(.workflow_run.head_repository_id == .workflow_run.repository_id)
  ] | sort_by(.created_at) | last
  | if . == null then empty else "\(.id) \(.workflow_run.id)" end'

if ! found=$(gh api -X GET "repos/$GITHUB_REPOSITORY/actions/artifacts" \
  -f name="$name" -f per_page=100 --jq "$newest"); then
  echo "::warning::could not list the artifacts named $name; the stage runs cold"
  exit 0
fi
if [ -z "$found" ]; then
  echo "no unexpired $name from master; the stage runs cold"
  exit 0
fi
read -r id run <<<"$found"
zip="$(mktemp)"
if ! gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$id/zip" >"$zip"; then
  echo "::warning::could not download artifact $id; the stage runs cold"
  rm -f "$zip"
  exit 0
fi
mkdir -p "$dest"
unzip -q -o "$zip" -d "$dest"
rm -f "$zip"
echo "restored $name from master run $run (artifact $id)"
