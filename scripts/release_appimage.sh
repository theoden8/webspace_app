#!/usr/bin/env bash
# The maintainer's AppImage release (PLATFORM-013), run on their own machine,
# where the signing key lives; CI never holds it.
#
#   scripts/release_appimage.sh key
#     Once: makes the release key (ed25519, signing only, no expiry, its
#     passphrase asked by gpg's own pinentry) and writes its public half to
#     linux/appimage/signing_key.asc, to commit. Every AppImage is signed by
#     it from then on: AppImageUpdate installs an update only when it is
#     signed by the key the installed copy carries, so a new key strands
#     every installed copy on its version.
#
#   scripts/release_appimage.sh publish vX.Y.Z [--replace]
#     Takes the AppDirs the Snap workflow built for the tag's commit, from
#     its run on the tag push, each checked by its build provenance to have
#     been made by that workflow from that tag on GitHub's runners; packs
#     each with linux/appimage/pack.sh, signed by the release key and pointing
#     its updates at this repository's latest GitHub release; checks each
#     signature with tool/appimage_signature.js; writes SHA256SUMS, signed;
#     and after asking, uploads them all to the tag's release, made from the
#     build's changelog when there is none. --replace overwrites files the
#     release already has.
#
# Needs gh (signed in), gpg, node, curl, tar and zstd.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pub="$root/linux/appimage/signing_key.asc"
owed="$root/linux/appimage/licences_owed.tsv"
uid='WebSpace AppImage releases'
fail() { echo "release_appimage.sh: $1" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null || fail "$c is not installed"; done; }

make_key() {
  need gpg
  [ ! -e "$pub" ] || fail "$pub exists: the AppImage has its release key, and a new one would strand every installed copy"
  status="$(mktemp)"
  trap 'rm -f "$status"' EXIT
  gpg --status-fd 3 --quick-generate-key "$uid" ed25519 sign never 3>"$status"
  fpr="$(awk '$2 == "KEY_CREATED" { print $4 }' "$status")"
  [ -n "$fpr" ] || fail "gpg made no key"
  gpg --armor --export "$fpr" > "$pub"
  cat <<EOF

The release key is $fpr.
  - Commit $pub: releases are checked against it, and users can check theirs.
  - Back up its secret half somewhere offline, with its passphrase:
      gpg --armor --export-secret-keys $fpr > webspace-appimage-release-key.asc
  - gpg wrote its revocation certificate to ~/.gnupg/openpgp-revocs.d/$fpr.rev;
    keep a copy apart from the key.
EOF
}

publish() {
  local tag="" replace=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --replace) replace=yes; shift ;;
      v*) tag=$1; shift ;;
      *) fail "unknown argument $1" ;;
    esac
  done
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "publish takes a release tag, vX.Y.Z"
  need gh gpg node curl tar zstd sha256sum
  [ -f "$pub" ] || fail "no $pub: run \`$0 key\` first"
  if grep -qv '^#' "$owed"; then
    fail "$(grep -cv '^#' "$owed") bundled packages' copyright files are still owed a reading ($owed)"
  fi
  fpr="$(gpg --with-colons --show-keys "$pub" | awk -F: '$1 == "fpr" { print $10; exit }')"
  gpg --list-secret-keys "$fpr" >/dev/null 2>&1 || fail "this machine holds no secret key for $fpr"
  gh auth status >/dev/null 2>&1 || fail "gh is not signed in: gh auth login"
  repo="$(cd "$root" && gh repo view --json nameWithOwner --jq .nameWithOwner)"

  git -C "$root" fetch --quiet origin "+refs/tags/$tag:refs/tags/$tag"
  sha="$(git -C "$root" rev-parse "$tag^{commit}")"
  version="${tag#v}"
  build="$(git -C "$root" show "$sha:pubspec.yaml" | sed -n 's/^version: *[^+]*+\([0-9]*\)$/\1/p')"
  run="$(gh run list --repo "$repo" --workflow snap.yml --event push --commit "$sha" --limit 20 \
    --json databaseId,headBranch,conclusion \
    --jq "[.[] | select(.headBranch == \"$tag\" and .conclusion == \"success\")][0].databaseId")"
  [ -n "$run" ] && [ "$run" != null ] || fail "no successful Snap workflow run for the push of $tag ($sha)"

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  echo "Taking the AppDirs of run $run of $repo's Snap workflow for $tag ($sha)"
  bash "$root/linux/appimage/fetch_tools.sh" "$work/tools" >/dev/null
  out="$work/out"
  mkdir -p "$out"
  export SOURCE_DATE_EPOCH
  SOURCE_DATE_EPOCH="$(git -C "$root" show -s --format=%ct "$sha")"
  files=()
  for pair in amd64:x86_64 arm64:aarch64; do
    snap_arch="${pair%%:*}" arch="${pair#*:}"
    gh run download "$run" --repo "$repo" --name "webspace-appdir-$snap_arch" --dir "$work/$snap_arch"
    tarball="$work/$snap_arch/webspace-appdir-$snap_arch.tar.zst"
    [ -f "$tarball" ] || fail "run $run's webspace-appdir-$snap_arch holds no $(basename "$tarball")"
    gh attestation verify "$tarball" --repo "$repo" \
      --signer-workflow "$repo/.github/workflows/snap.yml" \
      --source-ref "refs/tags/$tag" --source-digest "$sha" --deny-self-hosted-runners >/dev/null \
      || fail "$(basename "$tarball") has no provenance from $repo's Snap workflow at $tag"
    mkdir "$work/AppDir-$arch"
    zstd -dc "$tarball" | tar -x --no-same-owner -C "$work/AppDir-$arch"
    name="WebSpace-$version-$arch.AppImage"
    info="gh-releases-zsync|${repo%%/*}|${repo#*/}|latest|WebSpace-*-$arch.AppImage.zsync"
    bash "$root/linux/appimage/pack.sh" --appdir "$work/AppDir-$arch" --out "$out/$name" \
      --tools "$work/tools" --key "$fpr" --update-info "$info"
    node "$root/tool/appimage_signature.js" "$out/$name" --key "$pub" --update-info "$info"
    files+=("$name" "$name.zsync")
  done
  (
    cd "$out"
    sha256sum "${files[@]}" > SHA256SUMS
    gpg --armor --local-user "$fpr" --detach-sign SHA256SUMS
  )
  files+=(SHA256SUMS SHA256SUMS.asc)

  echo
  echo "Signed by $fpr, for $repo's release $tag:"
  (cd "$out" && ls -l "${files[@]}")
  read -r -p "Upload them? [y/N] " answer
  [ "$answer" = y ] || fail "nothing uploaded; the files were in $out"

  if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    notes="$work/notes.txt"
    git -C "$root" show "$sha:fastlane/metadata/android/en-US/changelogs/$build.txt" > "$notes" 2>/dev/null || : > "$notes"
    gh release create "$tag" --repo "$repo" --verify-tag --title "WebSpace $version" --notes-file "$notes"
  fi
  clobber=()
  [ "$replace" = no ] || clobber=(--clobber)
  (cd "$out" && gh release upload "$tag" --repo "$repo" ${clobber[@]+"${clobber[@]}"} "${files[@]}")
  echo "Published. A download is checked with:"
  echo "  node tool/appimage_signature.js WebSpace-$version-x86_64.AppImage --key linux/appimage/signing_key.asc"
}

case "${1:-}" in
  key) shift; make_key "$@" ;;
  publish) shift; publish "$@" ;;
  *) echo "usage: $0 key | $0 publish vX.Y.Z [--replace]" >&2; exit 2 ;;
esac
