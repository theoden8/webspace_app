#!/bin/sh
# Copyright (c) 2026 Kirill Rodriguez
# SPDX-License-Identifier: BSD-3-Clause
#
# Puts Monocypher 4.0.3's src/monocypher.c and src/monocypher.h beside this
# script, where cgo compiles them into package hiddenkey, after checking their
# SHA-256s against the pins below. A file that does not match is not copied.
#
#   ./fetch-monocypher.sh DIR   copy from DIR, a Monocypher tree or its src/
#   ./fetch-monocypher.sh       clone tag $MONOCYPHER_TAG of $MONOCYPHER_REPO
#
# The pins are of the files as tag 4.0.3 holds them in git (first line
# "// Monocypher version __git__"); a copy from elsewhere, such as a release
# tarball, may differ.
set -eu

MONOCYPHER_REPO=${MONOCYPHER_REPO:-https://github.com/LoupVaillant/Monocypher.git}
MONOCYPHER_TAG=${MONOCYPHER_TAG:-4.0.3}
SHA256_C=f1f838cdd483bdebe0df0ff5c5ed60535e496f769c6a2f933ac4c0b114207123
SHA256_H=fcaf6ed771358bb4f40fba016f6518ae86ec02b1b877d2cc35ad92d3a26fd7b3

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ $# -ge 1 ]; then
	src=$1
else
	git clone --quiet --depth 1 --branch "$MONOCYPHER_TAG" "$MONOCYPHER_REPO" "$tmp/monocypher"
	src=$tmp/monocypher
fi
[ -f "$src/src/monocypher.c" ] && src=$src/src

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

for pair in "monocypher.c $SHA256_C" "monocypher.h $SHA256_H"; do
	set -- $pair
	cp "$src/$1" "$tmp/$1"
	got=$(sha256 "$tmp/$1")
	if [ "$got" != "$2" ]; then
		echo "fetch-monocypher: $src/$1 has SHA-256 $got, want $2" >&2
		exit 1
	fi
done
cp "$tmp/monocypher.c" "$tmp/monocypher.h" "$here/"
echo "fetch-monocypher: monocypher.c and monocypher.h in $here"
