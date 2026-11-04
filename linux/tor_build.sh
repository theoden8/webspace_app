#!/usr/bin/env bash
# Builds tor from its source tree as a client alone and lays it out in
# <out dir> as the app runs it (lib/services/managed_tor_io.dart): tor, each
# shared library it links that a base system may lack, and a notice for each
# (TOR-027). linux/tor.cmake runs it. Configure is never given --enable-gpl,
# so the program is under tor's own BSD licence (LICENSE-001).
set -euo pipefail

src="${1:?usage: tor_build.sh <tor source tree> <out dir>}"
out="${2:?usage: tor_build.sh <tor source tree> <out dir>}"

# A build inside a snap or flatpak SDK carries that SDK's tool and library
# paths; tor links the build machine's own libraries, the ones copied below.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset LD_LIBRARY_PATH PKG_CONFIG_PATH CFLAGS CXXFLAGS CPPFLAGS LDFLAGS \
  PYTHONPATH GI_TYPELIB_PATH ACLOCAL_PATH XDG_DATA_DIRS

cd "$src"
# No optional library configure would otherwise take from the build machine:
# libcap has no switch, so its probe is answered for it.
./configure \
  --disable-module-relay \
  --disable-asciidoc \
  --disable-manpage \
  --disable-html-manual \
  --disable-unittests \
  --disable-systemd \
  --disable-lzma \
  --disable-zstd \
  --disable-seccomp \
  --disable-libscrypt \
  ac_cv_lib_cap_cap_init=no
make -j"$(nproc)"

rm -rf "$out"
mkdir -p "$out/docs"
install -m 755 src/app/tor "$out/tor"
install -m 644 LICENSE "$out/docs/tor.txt"

# What every Linux the app runs on has: glibc's own libraries and zlib.
base() {
  case "$1" in
    libc.so.6 | libm.so.6 | libz.so.1 | libpthread.so.0 | libdl.so.2 | ld-linux-*.so.*) return 0 ;;
    *) return 1 ;;
  esac
}

needed() {
  readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'
}

# The copyright file of the package that installed [library], with each
# common licence it points to, as docs/<package>.txt.
notice() {
  local real pkg copyright licence
  real="$(readlink -f "$1")"
  pkg="$(dpkg-query -S "$real" 2>/dev/null | head -1 | cut -d: -f1)" ||
    pkg=""
  if [ -z "$pkg" ]; then
    pkg="$(dpkg-query -S "${real#/usr}" 2>/dev/null | head -1 | cut -d: -f1)" || pkg=""
  fi
  copyright="/usr/share/doc/$pkg/copyright"
  if [ -z "$pkg" ] || [ ! -f "$copyright" ]; then
    echo "tor_build.sh: no package copyright for $real; build on a Debian or" \
      "Ubuntu system, or set WEBSPACE_TOR_SOURCE=none to build without tor" >&2
    exit 1
  fi
  [ -f "$out/docs/$pkg.txt" ] && return
  {
    cat "$copyright"
    grep -o '/usr/share/common-licenses/[A-Za-z0-9.+-]*' "$copyright" |
      sed 's/\.$//' | sort -u | while read -r licence; do
        [ -f "$licence" ] || continue
        printf '\n%s\n\n' "${licence##*/}"
        cat "$licence"
      done
  } > "$out/docs/$pkg.txt"
}

queue=("$out/tor")
while [ "${#queue[@]}" -gt 0 ]; do
  file="${queue[0]}"
  queue=("${queue[@]:1}")
  for lib in $(needed "$file"); do
    base "$lib" && continue
    [ -f "$out/$lib" ] && continue
    path="$(ldd "$file" | awk -v l="$lib" '$1 == l { print $3 }')"
    if [ ! -f "$path" ]; then
      echo "tor_build.sh: $file links $lib, which ldd does not find" >&2
      exit 1
    fi
    # In a flatpak build /usr is the runtime, which every install of the app
    # has, so its libraries are not copied, and their notices are its own.
    if [ -n "${FLATPAK_ID:-}" ] && [[ "$path" == /usr/* ]]; then
      continue
    fi
    cp -L "$path" "$out/$lib"
    chmod 644 "$out/$lib"
    notice "$path"
    queue+=("$out/$lib")
  done
done
