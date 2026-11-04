#!/bin/sh
# IPtProxy.xcframework, the pluggable transports the Apple app runs for Tor
# bridges (TOR-016), built from source with no GPL code in it (LICENSE-001).
#
# IPtProxy (MIT) wraps lyrebird's obfs4, meek_lite and webtunnel, snowflake
# and dnstt for gomobile. Two parts of lyrebird are GPL and are deleted before
# anything reads the tree: internal/x25519ell2, whose two functions obfs4's
# ntor handshake takes from go/hiddenkey instead, and meek_lite's uTLS round
# tripper, transports/meeklite/transport.go, whose one function the rest of
# meek_lite takes from go/meekutls/meekutls.go, copied in beside it.
# iptproxy.patch points the handshake at hiddenkey.
#
#   build.sh            bind IPtProxy.xcframework and collect LICENSES.txt
#                       beside this script, after prepare and check; nothing
#                       to do while both were built from these inputs
#   build.sh prepare    fetch and patch the sources into $IPTPROXY_WORK/src
#   build.sh check      prepare, then fail unless every package a target
#                       compiles is in a module licences.tsv names, none is a
#                       GPL package and no file it is built from names a GNU
#                       licence; unless meek_lite is built with
#                       go/meekutls/meekutls.go and not transport.go; unless
#                       go/meekutls and interop/ build against the modules
#                       the framework compiles, at its versions; and unless a
#                       built framework carries hiddenkey, go/meekutls's round
#                       tripper and no GPL package. With IPTPROXY_PREPARED=1,
#                       the tree already there instead
#   build.sh upstream   lyrebird at its tag, unmodified, built into
#                       $IPTPROXY_WORK/bin/lyrebird-upstream: the interop
#                       test's server (interop/), never part of the framework
#
# Each source is fetched at a pinned commit and its files checked against a
# SHA-256 (tree_sha256) before anything reads them; the Go modules under them
# against IPtProxy's go.sum; Monocypher by go/hiddenkey/fetch-monocypher.sh.
# go/meekutls/meekutls.go is ours, committed, adapted from meek's CC0 code.
# gomobile and gobind are built from the golang.org/x/mobile that go.sum
# pins. The Go is .go-version's. Nothing fetched or built here is committed:
# the trees go to $IPTPROXY_WORK, build/ by default.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
hiddenkey=$(cd "$here/../hiddenkey" && pwd)
meekutls=$(cd "$here/../meekutls" && pwd)
work=${IPTPROXY_WORK:-$here/build}
prepared=${IPTPROXY_PREPARED:-}
src=$work/src
out=$here/IPtProxy.xcframework
notices=$here/LICENSES.txt
# What the framework beside it was built from (inputs).
stamp_file=$here/IPtProxy.inputs

IPTPROXY_URL=https://github.com/tladesignz/IPtProxy.git
IPTPROXY_TAG=5.5.1
IPTPROXY_COMMIT=d4878bf7729902c1fb5e319d3b043c81388e0720
# Of IPtProxy.go/ and LICENSE only: the tag also holds a prebuilt framework.
IPTPROXY_SHA256=f9b1b210efa039e8d2a2fcbfb96e484d0e0abb00bb91bc049d2c60b60a5b4b81

LYREBIRD_URL=https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird.git
LYREBIRD_TAG=lyrebird-0.8.1
LYREBIRD_COMMIT=0b10edbb61e0ca6fb70c7d57aeaabf315f1fade1
LYREBIRD_SHA256=3a3129455403ab44fd5d6f03a1ddcba15c270c33d0d5193bd23509ed5c968e7f

# The commit IPtProxy 5.5.1's dnstt submodule names; it carries no tag.
DNSTT_URL=https://github.com/tladesignz/dnstt.git
DNSTT_COMMIT=f1b9b97a269f83bad41d2ceef291b4d2c161cd11
DNSTT_SHA256=0a2abeccdc26137acb1ba9888cb42e395ee0ea25ccfbb1ff0dfdf387c168e60f

# lyrebird's GPL parts, and the licence file that covers only them.
GPL_PATHS='internal/x25519ell2 transports/meeklite/transport.go LICENSE-GPL3.txt'
# The packages among them, as go list and a binary's symbols name them:
# meeklite stays, less its GPL file.
GPL_PACKAGES='lyrebird/internal/x25519ell2'
# go/meekutls's round tripper in lyrebird's tree, in transport.go's place,
# and its licence where the notices are collected from.
MEEKUTLS=transports/meeklite/meekutls.go
MEEKUTLS_LICENSE=LICENSE-meekutls
# Its type, as a binary's symbols name it.
MEEKUTLS_SYMBOL='lyrebird/transports/meeklite.(*meekutlsRoundTripper).RoundTrip'
# How a file names a GNU licence.
GPL_TEXT='GNU (Affero |Lesser |Library )?General Public Licen[cs]e|SPDX-License-Identifier:.*GPL'
# IPtProxy's snowflake proxy, which carries other people's traffic: the app
# only dials out, and this file alone brings in nine more modules.
UNUSED='IPtProxy.go/kindness.go'

# gomobile's Apple targets as go list sees them: GOOS/GOARCH/the tag gomobile
# adds to -tags=netcgo (golang.org/x/mobile cmd/gomobile/env.go).
TARGETS='ios/arm64/ios ios/amd64/ios darwin/arm64/macos darwin/amd64/macos'

: "${GOTOOLCHAIN:=go$(cat "$here/.go-version")}"
export GOTOOLCHAIN
export GOFLAGS=-mod=readonly

die() {
	echo "build.sh: $*" >&2
	exit 1
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$@" | cut -d' ' -f1
	else
		shasum -a 256 "$@" | cut -d' ' -f1
	fi
}

# The SHA-256 of a tree: of one line "<SHA-256 of the file>  <path>" per
# file, sorted by path.
tree_sha256() {
	[ -z "$(find "$1" -type l)" ] || die "$1 holds a symbolic link"
	(
		cd "$1"
		find . -type f | LC_ALL=C sort | while IFS= read -r f; do
			printf '%s  %s\n' "$(sha256 "$f")" "${f#./}"
		done
	) | sha256
}

# fetch DIR URL REF COMMIT SHA256 [PATH...]: COMMIT's files, or only its
# PATHs, into DIR. REF is what is fetched: a tag, or the commit itself.
# Only PATHs leave the other blobs on the server: a checkout fetches each
# missing blob on its own, which costs a round trip per file of a whole tree.
fetch() {
	dir=$1 url=$2 ref=$3 commit=$4 want=$5
	shift 5
	filter=--filter=blob:none
	[ $# -gt 0 ] || { set -- . && filter=--no-filter; }
	rm -rf "$dir"
	git init -q "$dir"
	git -C "$dir" remote add origin "$url"
	git -C "$dir" -c gc.auto=0 fetch -q --depth 1 "$filter" origin "$ref"
	got=$(git -C "$dir" rev-parse 'FETCH_HEAD^{commit}')
	[ "$got" = "$commit" ] || die "$url $ref is commit $got, want $commit"
	git -C "$dir" -c gc.auto=0 -c core.autocrlf=false checkout -q FETCH_HEAD -- "$@"
	rm -rf "$dir/.git"
	got=$(tree_sha256 "$dir")
	[ "$got" = "$want" ] || die "$url $ref: its files have SHA-256 $got, want $want"
}

prepare() {
	mkdir -p "$work"
	fetch "$src" "$IPTPROXY_URL" "refs/tags/$IPTPROXY_TAG" "$IPTPROXY_COMMIT" \
		"$IPTPROXY_SHA256" IPtProxy.go LICENSE
	# Into the module it covers, where its notice is collected from.
	mv "$src/LICENSE" "$src/IPtProxy.go/LICENSE"
	fetch "$src/dnstt" "$DNSTT_URL" "$DNSTT_COMMIT" "$DNSTT_COMMIT" "$DNSTT_SHA256"
	fetch "$src/lyrebird" "$LYREBIRD_URL" "refs/tags/$LYREBIRD_TAG" \
		"$LYREBIRD_COMMIT" "$LYREBIRD_SHA256"
	for p in $GPL_PATHS; do
		[ -e "$src/lyrebird/$p" ] || die "lyrebird has no $p; read again what in it is GPL"
		rm -rf "${src:?}/lyrebird/$p"
	done
	for p in $UNUSED; do
		[ -e "$src/$p" ] || die "IPtProxy has no $p"
		rm "$src/$p"
	done

	if [ ! -f "$hiddenkey/monocypher.c" ] || [ ! -f "$hiddenkey/monocypher.h" ]; then
		"$hiddenkey/fetch-monocypher.sh"
	fi
	mkdir "$src/hiddenkey"
	for f in LICENSE go.mod hiddenkey.go monocypher.c monocypher.h; do
		cp "$hiddenkey/$f" "$src/hiddenkey/"
	done
	cp "$meekutls/meekutls.go" "$src/lyrebird/$MEEKUTLS"
	cp "$meekutls/LICENSE" "$src/lyrebird/$MEEKUTLS_LICENSE"

	patch -d "$src" -p1 -N -F0 -s <"$here/iptproxy.patch" ||
		die "iptproxy.patch does not apply to these sources"

	for p in $GPL_PATHS; do
		[ ! -e "$src/lyrebird/$p" ] || die "lyrebird/$p is back after the patch"
	done
	if grep -rlE "$GPL_PACKAGES" "$src"; then
		die "the files above still name a deleted GPL package"
	fi
	if grep -rliE "$GPL_TEXT" "$src"; then
		die "the files above name a GNU licence"
	fi
	prepared=1
}

# go list in IPtProxy's module, once per target, over the packages the
# framework is built from: IPtProxy's and the one the bindings gomobile
# generates import.
list() {
	for t in $TARGETS; do
		goos=${t%%/*} rest=${t#*/}
		goarch=${rest%%/*} tag=${rest#*/}
		(cd "$src/IPtProxy.go" && GOOS=$goos GOARCH=$goarch CGO_ENABLED=1 \
			go list -deps -tags "netcgo,$tag" -f "$1" . golang.org/x/mobile/bind/seq)
	done | LC_ALL=C sort -u
}

module_dir() {
	(cd "$src/IPtProxy.go" &&
		go list -m -f '{{with .Replace}}{{.Dir}}{{else}}{{.Dir}}{{end}}' "$1")
}

licence_files() {
	find "$1" -maxdepth 1 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' \
		-o -iname 'NOTICE*' -o -iname 'PATENTS*' \) | LC_ALL=C sort
}

listed() {
	grep -v '^#' "$here/licences.tsv" | cut -f1 | grep -v '^$' | LC_ALL=C sort -u
}

check() {
	[ -n "$prepared" ] || prepare
	packages=$(list '{{if not .Standard}}{{.Module.Path}} {{.ImportPath}}{{end}}')
	[ -n "$packages" ] || die "go list found no packages"

	bad=$(printf '%s\n' "$packages" | grep -E "$GPL_PACKAGES" || true)
	[ -z "$bad" ] || die "a GPL package is compiled in (LICENSE-001):
$bad"

	printf '%s\n' "$packages" | cut -d' ' -f1 | LC_ALL=C sort -u >"$work/modules.compiled"
	listed >"$work/modules.listed"
	unlisted=$(LC_ALL=C comm -23 "$work/modules.compiled" "$work/modules.listed")
	[ -z "$unlisted" ] || die "compiled in, with no licence in licences.tsv:
$unlisted"
	stale=$(LC_ALL=C comm -13 "$work/modules.compiled" "$work/modules.listed")
	[ -z "$stale" ] || die "in licences.tsv, but not compiled in:
$stale"

	{
		list '{{if not .Standard}}{{$d := .Dir}}{{range .GoFiles}}{{printf "%s/%s\n" $d .}}{{end}}{{range .CgoFiles}}{{printf "%s/%s\n" $d .}}{{end}}{{range .CFiles}}{{printf "%s/%s\n" $d .}}{{end}}{{range .HFiles}}{{printf "%s/%s\n" $d .}}{{end}}{{range .MFiles}}{{printf "%s/%s\n" $d .}}{{end}}{{range .SFiles}}{{printf "%s/%s\n" $d .}}{{end}}{{range .EmbedFiles}}{{printf "%s/%s\n" $d .}}{{end}}{{end}}'
		while IFS= read -r module; do
			licence_files "$(module_dir "$module")"
		done <"$work/modules.compiled"
	} | grep -v '^$' >"$work/files.compiled"
	[ -s "$work/files.compiled" ] || die "go list found no files"
	named=$(tr '\n' '\0' <"$work/files.compiled" | xargs -0 grep -liE "$GPL_TEXT" || true)
	[ -z "$named" ] || die "these files the framework is built from name a GNU licence:
$named"

	# meek_lite: lyrebird's BSD files and go/meekutls's round tripper.
	meek=$src/lyrebird/${MEEKUTLS%/*}
	[ ! -e "$meek/transport.go" ] && ! grep -q '/transports/meeklite/transport\.go$' "$work/files.compiled" ||
		die "lyrebird's GPL transport.go is in meek_lite (LICENSE-001)"
	grep -q "/$MEEKUTLS\$" "$work/files.compiled" ||
		die "meek_lite is not built with go/meekutls/meekutls.go (TOR-016)"
	cmp -s "$meekutls/meekutls.go" "$src/lyrebird/$MEEKUTLS" ||
		die "lyrebird/$MEEKUTLS is not go/meekutls/meekutls.go"

	# What go/meekutls's and interop/'s tests build against is what the
	# framework compiles, at the versions it compiles.
	for dir in "$meekutls" "$here/interop"; do
		(cd "$dir" && go list -deps -test -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Version}}{{end}}{{end}}' ./...) |
			grep -v '^$' | LC_ALL=C sort -u >"$work/modules.tested"
		[ -s "$work/modules.tested" ] || die "go list found no module $dir builds against"
		while read -r module version; do
			built=$(cd "$src/IPtProxy.go" && go list -m -f '{{.Version}}' "$module" 2>/dev/null || true)
			[ "$built" = "$version" ] ||
				die "$dir builds against $module $version, the framework ${built:-not at all}"
		done <"$work/modules.tested"
	done

	if [ -d "$out" ]; then
		bins=$(find "$out" -type f -name IPtProxy)
		[ -n "$bins" ] || die "$out holds no IPtProxy binary"
		for bin in $bins; do
			grep -q 'webspace.local/hiddenkey' "$bin" ||
				die "$bin names no package of hiddenkey, so this scan cannot see package paths"
			! grep -qE "$GPL_PACKAGES" "$bin" || die "$bin carries a GPL package (LICENSE-001)"
			grep -qF "$MEEKUTLS_SYMBOL" "$bin" ||
				die "$bin carries no meek_lite built with go/meekutls (TOR-016)"
		done
	fi
	echo "build.sh: $(wc -l <"$work/modules.compiled" | tr -d ' ') modules, $(wc -l <"$work/files.compiled" | tr -d ' ') files, no GPL (LICENSE-001)"
}

# What a framework is built from: while it matches the one built, it is current.
inputs() {
	for f in "$here/build.sh" "$here/iptproxy.patch" "$here/.go-version" \
		"$here/licences.tsv" "$hiddenkey/hiddenkey.go" "$hiddenkey/go.mod" \
		"$hiddenkey/fetch-monocypher.sh" "$meekutls/meekutls.go" "$meekutls/LICENSE"; do
		sha256 "$f"
	done | sha256
}

# Each compiled module's licence files, and Go's, under the licence
# licences.tsv names for it.
collect_notices() {
	tab=$(printf '\t')
	{
		echo "IPtProxy.xcframework: IPtProxy $IPTPROXY_TAG with $LYREBIRD_TAG less its GPL"
		echo "parts, dnstt $DNSTT_COMMIT, go/hiddenkey and go/meekutls, built by"
		echo "go/iptproxy/build.sh."
		grep -v '^#' "$here/licences.tsv" | grep -v '^$' | while IFS=$tab read -r module licence; do
			echo
			echo "================================================================================"
			echo "$(cd "$src/IPtProxy.go" && go list -m -f '{{.Path}} {{.Version}}{{with .Replace}} => {{.Path}}{{end}}' "$module"): $licence"
			echo "================================================================================"
			licence_files "$(module_dir "$module")" | while IFS= read -r f; do
				echo
				echo "--- $(basename "$f")"
				echo
				cat "$f"
			done
		done
		echo
		echo "================================================================================"
		echo "Go $(go env GOVERSION), its runtime and standard library: BSD-3-Clause"
		echo "================================================================================"
		echo
		cat "$(go env GOROOT)/LICENSE"
	} >"$1"
}

bind() {
	stamp=$(inputs)
	if [ -d "$out" ] && [ -f "$notices" ] && [ "$(cat "$stamp_file" 2>/dev/null || true)" = "$stamp" ]; then
		echo "build.sh: $out is current"
		return
	fi
	prepare
	check
	(cd "$src/IPtProxy.go" && GOBIN="$work/bin" go install \
		golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind)
	rm -rf "$work/IPtProxy.xcframework"
	# The flags IPtProxy's own build.sh binds with.
	(cd "$src/IPtProxy.go" && PATH="$work/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=11.0 \
		gomobile bind -target=ios,iossimulator,macos -iosversion=15.0 \
		-tags=netcgo -trimpath -ldflags='-s -w -checklinkname=0' \
		-o "$work/IPtProxy.xcframework" -v .)
	collect_notices "$work/LICENSES.txt"
	rm -rf "$out" "$notices" "$stamp_file"
	mv "$work/IPtProxy.xcframework" "$out"
	mv "$work/LICENSES.txt" "$notices"
	check
	echo "$stamp" >"$stamp_file"
}

upstream() {
	fetch "$work/upstream-lyrebird" "$LYREBIRD_URL" "refs/tags/$LYREBIRD_TAG" \
		"$LYREBIRD_COMMIT" "$LYREBIRD_SHA256"
	(cd "$work/upstream-lyrebird" && go build -trimpath -o "$work/bin/lyrebird-upstream" ./cmd/lyrebird)
}

case "${1:-}" in
'') bind ;;
prepare) prepare ;;
check) check ;;
upstream) upstream ;;
*) die "usage: build.sh [prepare|check|upstream]" ;;
esac
