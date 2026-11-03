# The built-in Tor on Linux (TOR-027): tor built from the Tor Project's
# signed source release by linux/tor_build.sh, as a client alone, with each
# shared library it links that a base system may lack and a notice for each,
# installed beside the executable at lib/tor/, where the app looks first
# (lib/services/managed_tor_io.dart). Every package made from the bundle
# directory (the native tarball, the snap, the flatpak) carries it.
#
# Never tor's GeoIP tables (LICENSE-002): the app downloads one on the
# device when a site pins an exit country (TOR-014). The build installs only
# what tor_build.sh lays out, which takes tor's program and licence alone
# from the source tree.
#
# WEBSPACE_TOR_SOURCE (environment) names the source tarball for a build
# with no network, as flatpak-builder runs, which lists it as a source with
# the same checksum; `none` builds without, and the app then runs a tor the
# machine has, or offers no Tor. A cross build is one without: tor is built
# for the machine that builds it.
#
# To bump: pick a release under
# https://archive.torproject.org/tor-package-archive/, check its
# `.sha256sum` against the `.sha256sum.asc` signatures of the tor release
# signing keys, and copy the tarball's SHA-256 here.

set(TOR_VERSION "0.4.9.15")
set(TOR_SOURCE_SHA256
  "1911f5b216a6814ed143a08bbcff1c6dc96d2ca3b505df9a21876080a92963f3")
set(_WEBSPACE_TOR_BUILD "${CMAKE_CURRENT_LIST_DIR}/tor_build.sh")

# Builds tor for a build targeting ${TOR_TARGET_ARCH} (x64, arm64), keeping
# the downloaded source in ${TOR_DOWNLOAD_DIR}, and installs it into
# ${TOR_INSTALL_DIR}.
function(webspace_build_tor TOR_TARGET_ARCH TOR_DOWNLOAD_DIR TOR_INSTALL_DIR)
  set(source "$ENV{WEBSPACE_TOR_SOURCE}")
  if(source STREQUAL "none")
    message(STATUS "Tor: WEBSPACE_TOR_SOURCE=none, building without tor")
    return()
  endif()
  if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(host_arch "arm64")
  else()
    set(host_arch "x64")
  endif()
  if(NOT TOR_TARGET_ARCH STREQUAL host_arch)
    message(STATUS
      "Tor: a ${TOR_TARGET_ARCH} build on ${host_arch}; building without "
      "tor, so the app runs one the machine has")
    return()
  endif()
  if(source STREQUAL "")
    set(source
      "https://archive.torproject.org/tor-package-archive/tor-${TOR_VERSION}.tar.gz")
  endif()

  include(ExternalProject)
  set(out "${CMAKE_BINARY_DIR}/tor/out")
  set(extract_timestamp)
  if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.24)
    set(extract_timestamp DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  endif()
  ExternalProject_Add(webspace_tor
    URL "${source}"
    URL_HASH SHA256=${TOR_SOURCE_SHA256}
    TLS_VERIFY ON
    DOWNLOAD_DIR "${TOR_DOWNLOAD_DIR}"
    ${extract_timestamp}
    PREFIX "${CMAKE_BINARY_DIR}/tor"
    BUILD_IN_SOURCE TRUE
    CONFIGURE_COMMAND ""
    BUILD_COMMAND bash "${_WEBSPACE_TOR_BUILD}" <SOURCE_DIR> "${out}"
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS "${out}/tor")
  install(DIRECTORY "${out}/"
    DESTINATION "${TOR_INSTALL_DIR}"
    USE_SOURCE_PERMISSIONS
    COMPONENT Runtime)
  message(STATUS "Tor: building tor ${TOR_VERSION} from source")
endfunction()
