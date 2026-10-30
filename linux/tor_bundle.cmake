# The built-in Tor on Linux (TOR-027): tor, the libevent and OpenSSL it
# links, the lyrebird pluggable transport and their licence notices, taken
# from the Tor Project's Tor Expert Bundle at a pinned release and checksum
# and installed beside the executable at lib/tor/, where the app looks
# first (lib/services/managed_tor_io.dart). Every package format that ships
# the bundle directory (the native tarball, an AppImage, a flatpak or snap
# built from it) carries tor with it.
#
# Never the bundle's GeoIP tables (LICENSE-002): the app downloads one on
# the device when a site pins an exit country (TOR-014). Nor conjure-client:
# no transport the app offers runs on it, and one of its dependencies is
# LGPL-3.0, which LICENSE-001 keeps out of a shipped binary. The files below
# are named one by one, so nothing else in the archive can come along.
#
# WEBSPACE_TOR_BUNDLE (environment) names the archive for a build with no
# network, as flatpak-builder runs, which lists it as a source with the same
# checksum; `none` builds without, and the app then runs a tor the machine
# has (a flatpak or snap module of its own, or the distribution's package),
# or offers no Tor. The Tor Project publishes no bundle for arm64 Linux, so
# an arm64 build is one without.
#
# To bump: pick a release under https://dist.torproject.org/torbrowser/,
# check `sha256sums-signed-build.txt` against its `.asc` with the Tor Browser
# Developers signing key (EF6E 286D DA85 EA2A 4BA7 DE68 4E2C 6E87 9329 8290),
# and copy the x86_64 expert bundle's line here.

set(TOR_EXPERT_BUNDLE_VERSION "15.0.26")
set(TOR_EXPERT_BUNDLE_SHA256
  "19cf18726eecb362e0f21d27afa9ea9efe5da928bfdfbb1ceb5fe54519e87f4a")

# Installs the bundle's tor into ${TOR_INSTALL_DIR}, for a build targeting
# ${TOR_TARGET_ARCH} (x64, arm64), working in ${TOR_WORK_DIR}.
function(webspace_bundle_tor TOR_TARGET_ARCH TOR_WORK_DIR TOR_INSTALL_DIR)
  set(source "$ENV{WEBSPACE_TOR_BUNDLE}")
  if(source STREQUAL "none")
    message(STATUS "Tor: WEBSPACE_TOR_BUNDLE=none, building without tor")
    return()
  endif()
  if(NOT TOR_TARGET_ARCH STREQUAL "x64")
    message(STATUS
      "Tor: no Tor Expert Bundle for ${TOR_TARGET_ARCH}; building without "
      "tor, so the app runs one the machine has")
    return()
  endif()

  file(MAKE_DIRECTORY "${TOR_WORK_DIR}")
  set(name "tor-expert-bundle-linux-x86_64-${TOR_EXPERT_BUNDLE_VERSION}.tar.gz")
  set(archive "${TOR_WORK_DIR}/${name}")
  if(source STREQUAL "")
    file(DOWNLOAD
      "https://dist.torproject.org/torbrowser/${TOR_EXPERT_BUNDLE_VERSION}/${name}"
      "${archive}"
      EXPECTED_HASH SHA256=${TOR_EXPERT_BUNDLE_SHA256}
      TLS_VERIFY ON
      STATUS status)
    list(GET status 0 code)
    if(NOT code EQUAL 0)
      list(GET status 1 reason)
      file(REMOVE "${archive}")
      message(FATAL_ERROR
        "Tor: could not download ${name}: ${reason}. A build with no "
        "network names the archive in WEBSPACE_TOR_BUNDLE, or sets it to "
        "`none` to build without tor.")
    endif()
  else()
    file(SHA256 "${source}" actual)
    if(NOT actual STREQUAL TOR_EXPERT_BUNDLE_SHA256)
      message(FATAL_ERROR
        "Tor: ${source} has SHA-256 ${actual}, not the pinned "
        "${TOR_EXPERT_BUNDLE_SHA256} of ${name}")
    endif()
    set(archive "${source}")
  endif()

  set(extracted "${TOR_WORK_DIR}/tor-expert-bundle-${TOR_EXPERT_BUNDLE_VERSION}")
  if(NOT EXISTS "${extracted}/tor/tor")
    file(REMOVE_RECURSE "${extracted}")
    file(MAKE_DIRECTORY "${extracted}")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xzf "${archive}"
      WORKING_DIRECTORY "${extracted}"
      RESULT_VARIABLE untarred)
    if(NOT untarred EQUAL 0)
      message(FATAL_ERROR "Tor: could not extract ${archive}")
    endif()
  endif()

  install(PROGRAMS "${extracted}/tor/tor"
    DESTINATION "${TOR_INSTALL_DIR}" COMPONENT Runtime)
  install(FILES
      "${extracted}/tor/libevent-2.1.so.7"
      "${extracted}/tor/libssl.so.3"
      "${extracted}/tor/libcrypto.so.3"
    DESTINATION "${TOR_INSTALL_DIR}" COMPONENT Runtime)
  install(PROGRAMS "${extracted}/tor/pluggable_transports/lyrebird"
    DESTINATION "${TOR_INSTALL_DIR}/pluggable_transports" COMPONENT Runtime)
  install(FILES
      "${extracted}/docs/tor.txt"
      "${extracted}/docs/libevent.txt"
      "${extracted}/docs/openssl.txt"
      "${extracted}/docs/lyrebird.txt"
    DESTINATION "${TOR_INSTALL_DIR}/docs" COMPONENT Runtime)
  message(STATUS "Tor: bundling tor from ${name}")
endfunction()
