#!/usr/bin/env bash
# Makes the AppImage's AppDir from what snapcraft primed for the snap
# (PLATFORM-013): the app's bundle in opt/webspace and the WebKit and libwpe
# it built in usr/, laid out as in the snap, with every shared library they
# link taken from the build host (Ubuntu 24.04, the snap's base) but those
# linux/appimage/excludelist leaves to the machine, and the modules GLib, GTK
# and WebKit load at run time: the GIO modules (TLS, proxies, settings), the
# gdk-pixbuf loaders, and the GStreamer plugins WebKit plays media with. Each
# ELF file finds what it links by its RUNPATH, so nothing the app starts
# inherits a library path. Each bundled package's copyright file goes with
# it, for tool/check_bundle_licences.js. linux/appimage/AppRun points WebKit
# (WEBSPACE_WPE_ROOT), GIO, gdk-pixbuf and GStreamer at the bundle.
#
#   build_appdir.sh PRIME_DIR APPDIR   the AppDir, made afresh
#   build_appdir.sh packages           the Ubuntu packages it takes modules from
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# The packages whose modules the AppDir carries; what they link comes by the
# closure below. Ubuntu 24.04 has no dav1d plugin: AV1 plays through aom.
module_packages=(
  glib-networking libgtk-3-common libgdk-pixbuf-2.0-0 librsvg2-common
  libgstreamer1.0-0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good
  gstreamer1.0-plugins-bad gstreamer1.0-gl gstreamer1.0-pipewire
)
# What builds the AppDir.
tool_packages=(patchelf libglib2.0-bin)

if [ "${1:-}" = packages ]; then
  echo "${module_packages[*]} ${tool_packages[*]}"
  exit 0
fi

prime="${1:?usage: build_appdir.sh PRIME_DIR APPDIR | build_appdir.sh packages}"
appdir="$(realpath -m "${2:?usage: build_appdir.sh PRIME_DIR APPDIR}")"
fail() { echo "build_appdir.sh: $1" >&2; exit 1; }

for p in "${module_packages[@]}" "${tool_packages[@]}"; do
  dpkg-query -W -f '${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' \
    || fail "$p is not installed: apt-get install \$(bash $0 packages)"
done

webkit="$(compgen -G "$prime/usr/lib/*/libWPEWebKit-2.0.so.1" | head -1)" \
  || fail "$prime holds no usr/lib/<triplet>/libWPEWebKit-2.0.so.1"
triplet="$(basename "$(dirname "$webkit")")"
[ -x "$prime/opt/webspace/webspace_app" ] || fail "$prime holds no opt/webspace/webspace_app"

# GIO's TLS module, which libsoup needs for HTTPS. Not the desktop's proxy
# settings: GNOME's module reads them through dconf, whose copyright names the
# GPL, and libproxy's brings a JavaScript engine; the app's own proxy settings
# route a site.
gio_modules=(libgiognutls.so)
# The GStreamer plugins WebKit's media players and capture use, by plugin
# name. None is GPL: Ubuntu builds gst-libav's FFmpeg under the GPL, so
# H.264 and AAC do not play; VP8, VP9, AV1, Opus and Vorbis do.
gst_plugins=(
  coreelements app audioconvert audiomixer audioparsers audiorate audioresample
  autodetect codecalpha codectimestamper debugutilsbad encoding inter
  interleave isomp4 matroska ogg opengl opus opusparse pbtypes pipewire
  playback pulseaudio rawparse subparse typefindfunctions videoconvertscale
  videofilter videoparsersbad videorate volume vorbis vpx aom wavparse
)
# gdk-pixbuf has PNG and JPEG built in; GTK's symbolic icons are SVG.
pixbuf_loaders=(svg gif ico bmp)
# Sonames nothing loads on Linux: libdartjni.so links the JVM, used only on
# Android.
missing_ok=(libjvm.so)

rm -rf "$appdir"
mkdir -p "$appdir"
cp -a "$prime/opt" "$prime/usr" "$appdir/"
libdir="$appdir/usr/lib/$triplet"
# The plugin copies WPE into the bundle; the app loads the build's own, the
# one its helper processes run against, as the snap does.
rm -f "$appdir"/opt/webspace/lib/libWPEWebKit-*.so* "$appdir"/opt/webspace/lib/libwpe-*.so*

host_lib="/usr/lib/$triplet"
mkdir -p "$libdir/gio/modules" "$libdir/gstreamer-1.0" "$libdir/gstreamer1.0/gstreamer-1.0" \
  "$libdir/gdk-pixbuf-2.0/2.10.0/loaders" "$appdir/usr/share/glib-2.0/schemas"
schemas="$(mktemp -d)"
trap 'rm -rf "$schemas"' EXIT
taken=()
for m in "${gio_modules[@]}"; do
  install -m 644 "$host_lib/gio/modules/$m" "$libdir/gio/modules/"
  taken+=("$host_lib/gio/modules/$m")
done
for p in "${gst_plugins[@]}"; do
  install -m 644 "$host_lib/gstreamer-1.0/libgst$p.so" "$libdir/gstreamer-1.0/"
  taken+=("$host_lib/gstreamer-1.0/libgst$p.so")
done
scanner="$host_lib/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner"
install -m 755 "$scanner" "$libdir/gstreamer1.0/gstreamer-1.0/"
taken+=("$scanner")
for l in "${pixbuf_loaders[@]}"; do
  install -m 644 "$host_lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-$l.so" "$libdir/gdk-pixbuf-2.0/2.10.0/loaders/"
  taken+=("$host_lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-$l.so")
done
# GTK's own schemas, which its file chooser aborts without, compiled: their
# sources carry the LGPL's notice, which ships only among the notices.
while read -r f; do
  case "$f" in
    /usr/share/glib-2.0/schemas/*.xml)
      install -m 644 "$f" "$schemas/"
      taken+=("$f") ;;
  esac
done < <(dpkg-query -L libgtk-3-common)
glib-compile-schemas --targetdir="$appdir/usr/share/glib-2.0/schemas" "$schemas"

# The host's shared libraries by soname, for this triplet.
declare -A host
while read -r soname path; do
  [ -n "${host[$soname]:-}" ] || host[$soname]=$path
done < <(ldconfig -p | awk -v t="/$triplet/" 'index($NF, t) { print $1, $NF }')
declare -A excluded
while IFS=$'\t' read -r soname _; do
  case "$soname" in ''|'#'*) continue ;; esac
  excluded[$soname]=1
done < "$here/excludelist"
for s in "${missing_ok[@]}"; do excluded[$s]=1; done

is_elf() { [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; }
elves() { find "$appdir" -type f -print0 | while IFS= read -r -d '' f; do is_elf "$f" && printf '%s\n' "$f"; done; }

# Every soname the AppDir's files and the copies link, recursively, unless
# the machine keeps it or the file finds it already: in the bundled libraries,
# beside it (tor's $ORIGIN), or among the Flutter bundle's, which the app
# loads first.
found() {
  [ -e "$libdir/$2" ] || [ -e "$(dirname "$1")/$2" ] || [ -e "$appdir/opt/webspace/lib/$2" ]
}
declare -A have
queue=()
while IFS= read -r f; do queue+=("$f"); done < <(elves)
unresolved=()
while [ "${#queue[@]}" -gt 0 ]; do
  f="${queue[0]}"
  queue=("${queue[@]:1}")
  while IFS= read -r soname; do
    [ -n "$soname" ] || continue
    [ -z "${excluded[$soname]:-}" ] || continue
    found "$f" "$soname" && continue
    [ -z "${have[$soname]:-}" ] || continue
    # A library private to its package sits in a directory of its own that
    # its users' RUNPATH names (libpulse's pulseaudio/), out of the cache.
    path="${host[$soname]:-$(find "$host_lib" -mindepth 2 -maxdepth 2 -name "$soname" -print -quit)}"
    if [ -z "$path" ]; then
      unresolved+=("$soname (linked by ${f#"$appdir"/})")
      have[$soname]=1
      continue
    fi
    install -m 644 "$(readlink -f "$path")" "$libdir/$soname"
    have[$soname]=1
    taken+=("$path")
    queue+=("$libdir/$soname")
  done < <(patchelf --print-needed "$f" 2>/dev/null || true)
done
[ "${#unresolved[@]}" -eq 0 ] || fail "no library on the build host for: ${unresolved[*]}"

# Each ELF file that links anything finds the bundled libraries from where it
# sits, and those beside it (the Flutter bundle's, tor's). Of the RUNPATH it
# had, what is relative to it (the app's $ORIGIN/lib) stays first; an absolute
# entry names the build machine (its build tree, the GNOME SDK snap, libpulse's
# private directory) and would load that machine's libraries wherever it
# exists.
while IFS= read -r f; do
  needed="$(patchelf --print-needed "$f" 2>/dev/null)" || continue
  [ -n "$needed" ] || continue
  dir="$(dirname "$f")"
  rel="$(realpath --relative-to="$dir" "$libdir")"
  wants=()
  if [ "$rel" = . ]; then
    wants+=('$ORIGIN')
  else
    wants+=("\$ORIGIN/$rel")
    while IFS= read -r soname; do
      if [ -e "$dir/$soname" ]; then wants=('$ORIGIN' "${wants[@]}"); break; fi
    done <<<"$needed"
  fi
  had="$(patchelf --print-rpath "$f")"
  rpath=''
  IFS=: read -r -a entries <<<"$had"
  for want in ${entries[@]+"${entries[@]}"} "${wants[@]}"; do
    case "$want" in '$ORIGIN'|'$ORIGIN/'*) ;; *) continue ;; esac
    case ":$rpath:" in *":$want:"*) ;; *) rpath="${rpath:+$rpath:}$want" ;; esac
  done
  [ "$rpath" = "$had" ] || patchelf --set-rpath "$rpath" "$f"
done < <(elves)

# gdk-pixbuf reads its loaders from a cache that names them by absolute path;
# AppRun writes it for wherever the AppImage is mounted.
GDK_PIXBUF_MODULEDIR="$libdir/gdk-pixbuf-2.0/2.10.0/loaders" \
  "$host_lib/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders" \
  | sed -e '/^#/d' -e "s|\"$appdir/|\"@APPDIR@/|" > "$libdir/gdk-pixbuf-2.0/2.10.0/loaders.cache.in"
grep -q '"@APPDIR@/.*libpixbufloader-svg.so"' "$libdir/gdk-pixbuf-2.0/2.10.0/loaders.cache.in" \
  || fail "the pixbuf loader cache names no SVG loader in the AppDir"
if grep -q "$appdir" "$libdir/gdk-pixbuf-2.0/2.10.0/loaders.cache.in"; then
  fail "the pixbuf loader cache still names the build's AppDir"
fi

# The copyright file of each package something came from (LICENSE-003).
declare -A packages
for path in "${taken[@]}"; do
  owner=''
  for candidate in "$path" "$(readlink -f "$path")" "${path/#\/usr\/lib\//\/lib\/}" "${path/#\/lib\//\/usr\/lib\/}"; do
    owner="$(dpkg-query -S "$candidate" 2>/dev/null | head -1 | cut -d: -f1)" && [ -n "$owner" ] && break
  done
  [ -n "$owner" ] || fail "no package owns $path"
  packages[$owner]=1
done
for p in "${!packages[@]}"; do
  [ -f "/usr/share/doc/$p/copyright" ] || fail "$p has no /usr/share/doc/$p/copyright"
  [ -e "$appdir/usr/share/doc/$p/copyright" ] && continue
  install -D -m 644 "/usr/share/doc/$p/copyright" "$appdir/usr/share/doc/$p/copyright"
done

# The AppImage's own entry point, desktop entry and icon.
id="$(basename "$(compgen -G "$appdir/usr/share/applications/*.desktop" | head -1)" .desktop)"
[ -n "$id" ] || fail "$prime holds no desktop entry"
sed "s|@TRIPLET@|$triplet|g; s|@APPLICATION_ID@|$id|g" "$here/AppRun" > "$appdir/AppRun"
chmod 755 "$appdir/AppRun"
# The snap's entry names its icon by a path in the snap.
sed -i "s|^Icon=.*|Icon=$id|" "$appdir/usr/share/applications/$id.desktop"
ln -s "usr/share/applications/$id.desktop" "$appdir/$id.desktop"
icon="$appdir/usr/share/icons/hicolor/512x512/apps/$id.png"
[ -f "$icon" ] || fail "$prime holds no 512x512 icon for $id"
ln -s "usr/share/icons/hicolor/512x512/apps/$id.png" "$appdir/$id.png"
ln -s "$id.png" "$appdir/.DirIcon"

echo "build_appdir.sh: $appdir with ${#packages[@]} packages' libraries and modules"
