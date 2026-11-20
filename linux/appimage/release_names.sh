# Sourced. A released AppImage's file name and the update information it
# carries (PLATFORM-013): AppImageUpdate reads the latest GitHub release of the
# repository named and takes the .zsync whose name the pattern matches, so the
# two change together.
#
#   appimage_name VERSION ARCH          WebSpace-VERSION-ARCH.AppImage
#   appimage_update_info OWNER/REPO ARCH

appimage_name() {
  echo "WebSpace-$1-$2.AppImage"
}

appimage_update_info() {
  echo "gh-releases-zsync|${1%%/*}|${1#*/}|latest|$(appimage_name '*' "$2").zsync"
}
