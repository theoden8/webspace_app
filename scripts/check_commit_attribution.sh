#!/usr/bin/env bash
#
# Commit attribution gate.
#
# A replay (rebase, cherry-pick, squash) must not rewrite who wrote a commit,
# and must not grow its trailer block. Both are silent: nothing fails, the
# commit just quietly credits the wrong person or accumulates a second
# Co-Authored-By on every pass.
#
# Checks every commit on this branch that is not on the base:
#   1. no Signed-off-by (this repo does not use DCO)
#   2. at most one Co-Authored-By per identity
#   3. a Cherry-picked-from commit is authored by someone other than the
#      committer, which is what preserving the original author looks like
#
# Base defaults to origin/master; override with $BASE. Skips when the base is
# unreachable (a shallow clone with no base fetched) rather than failing.

set -e

BASE="${BASE:-origin/master}"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "check_commit_attribution: base '$BASE' not found, skipping."
    echo "  (shallow clone? try: git fetch --depth=50 origin master)"
    exit 0
fi

if ! MERGE_BASE=$(git merge-base "$BASE" HEAD 2>/dev/null); then
    echo "check_commit_attribution: no merge base with '$BASE', skipping."
    exit 0
fi

COMMITS=$(git rev-list "$MERGE_BASE..HEAD")
if [ -z "$COMMITS" ]; then
    echo "check_commit_attribution: no commits ahead of $BASE."
    exit 0
fi

EXIT_CODE=0
COUNT=0

for SHA in $COMMITS; do
    COUNT=$((COUNT + 1))
    SHORT=$(git rev-parse --short "$SHA")
    SUBJECT=$(git show -s --format=%s "$SHA")
    BODY=$(git show -s --format=%B "$SHA")

    SIGNOFFS=$(printf '%s\n' "$BODY" | grep -c '^Signed-off-by:' || true)
    if [ "$SIGNOFFS" -ne 0 ]; then
        echo "FAIL $SHORT $SUBJECT"
        echo "  carries $SIGNOFFS Signed-off-by trailer(s); this repo does not use DCO."
        echo "  Do not commit with -s, and do not rebase with --signoff."
        EXIT_CODE=1
    fi

    DUPES=$(printf '%s\n' "$BODY" \
        | grep '^Co-Authored-By:' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[[:space:]]\{1,\}/ /g; s/[[:space:]]*$//' \
        | sort | uniq -d || true)
    if [ -n "$DUPES" ]; then
        echo "FAIL $SHORT $SUBJECT"
        printf '%s\n' "$DUPES" | while IFS= read -r LINE; do
            echo "  repeated trailer: $LINE"
        done
        echo "  Each co-author appears once. A replay must not stack another copy."
        EXIT_CODE=1
    fi

    if printf '%s\n' "$BODY" | grep -q '^Cherry-picked-from:'; then
        AUTHOR=$(git show -s --format='%an <%ae>' "$SHA")
        COMMITTER=$(git show -s --format='%cn <%ce>' "$SHA")
        if [ "$AUTHOR" = "$COMMITTER" ]; then
            echo "FAIL $SHORT $SUBJECT"
            echo "  Cherry-picked-from, but author == committer ($AUTHOR)."
            echo "  Keep the original author: git commit --author=\"Name <email>\"."
            EXIT_CODE=1
        fi
    fi
done

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "check_commit_attribution: $COUNT commit(s) since $BASE, attribution intact."
fi

exit $EXIT_CODE
