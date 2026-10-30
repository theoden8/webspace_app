# Project-level configuration.
cmake_minimum_required(VERSION 3.10)
project(runner LANGUAGES CXX)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-deprecated-literal-operator")

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "webspace_app")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
# The flatpak's manifest passes its own id (PLATFORM-009); every other build
# keeps the one releases have shipped under.
if(NOT "$ENV{WEBSPACE_APPLICATION_ID}" STREQUAL "")
  set(APPLICATION_ID "$ENV{WEBSPACE_APPLICATION_ID}")
else()
  set(APPLICATION_ID "org.codeberg.theoden8.webspace")
endif()

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
# Screen sharing (SHARE-018): the desktop portal's ScreenCast over GDBus, and
# the PipeWire stream it hands over.
pkg_check_modules(SCREEN_SHARE REQUIRED IMPORTED_TARGET
  libpipewire-0.3 gio-unix-2.0)

add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Define the application target. To change its name, change BINARY_NAME above,
# not the value here, or `flutter run` will no longer work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "egress_relay.cc"
  "egress_relay_core.cc"
  "my_application.cc"
  "screen_share.cc"
  "window_capture.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::SCREEN_SHARE)
# The egress relay (NETIF-003) serves each connection on a thread of its own.
find_package(Threads REQUIRED)
target_link_libraries(${BINARY_NAME} PRIVATE Threads::Threads)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Localizations (LOC-012): write the AppLocalizations API before Flutter
# compiles Dart; the translations ship as the ARB assets.
get_directory_property(FLUTTER_ROOT DIRECTORY ${FLUTTER_MANAGED_DIR} DEFINITION FLUTTER_ROOT)
add_custom_target(webspace_l10n
  COMMAND "${FLUTTER_ROOT}/bin/dart" "${CMAKE_CURRENT_SOURCE_DIR}/../tool/gen_l10n.dart"
  VERBATIM)
add_dependencies(flutter_assemble webspace_l10n)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# webspace_adblock — Rust-backed ABP engine. Built out-of-tree by
# `scripts/build_rust.sh linux` which drops the .so at
# `linux/lib/libwebspace_adblock.so` (relative to repo root). Install
# only when present so the build still works without the Rust step
# (Dart fallback engine handles that case at runtime via
# AdblockEngine.load() returning null).
set(WEBSPACE_ADBLOCK_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/lib/libwebspace_adblock.so")

# Auto-build the Rust .so as part of the Flutter Linux build. The
# custom command keys on Cargo.lock + every src file under the crate
# so unchanged builds skip the cargo invocation entirely. Skipping
# the rule (when cargo isn't available, or the crate dir is missing)
# falls through to the install-when-present rule below — same
# graceful-fallback contract as Android's -PskipRustAdblock=true.
set(RUST_CRATE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../rust/webspace_adblock")
set(RUST_BUILD_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/build_rust.sh")

find_program(CARGO_EXECUTABLE cargo)
set(WEBSPACE_ADBLOCK_AUTOBUILT FALSE)
if(EXISTS "${RUST_CRATE_DIR}/Cargo.toml" AND CARGO_EXECUTABLE)
  file(GLOB_RECURSE RUST_SRC_FILES "${RUST_CRATE_DIR}/src/*.rs")
  add_custom_command(
    OUTPUT "${WEBSPACE_ADBLOCK_SO}"
    COMMAND bash "${RUST_BUILD_SCRIPT}" linux
    DEPENDS
      "${RUST_CRATE_DIR}/Cargo.toml"
      "${RUST_CRATE_DIR}/Cargo.lock"
      ${RUST_SRC_FILES}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
    COMMENT "Building webspace_adblock (Rust)"
    VERBATIM
  )
  add_custom_target(webspace_adblock_so ALL
    DEPENDS "${WEBSPACE_ADBLOCK_SO}")
  add_dependencies(${BINARY_NAME} webspace_adblock_so)
  set(WEBSPACE_ADBLOCK_AUTOBUILT TRUE)
else()
  message(STATUS
    "webspace_adblock: cargo or crate dir not found; "
    "skipping Rust auto-build. Engine will fall back to Dart parser at runtime.")
endif()

# Install when auto-built (the OUTPUT will exist post-build) OR when a
# pre-built .so is already on disk (legacy `scripts/build_rust.sh` path).
if(WEBSPACE_ADBLOCK_AUTOBUILT)
  install(FILES "${WEBSPACE_ADBLOCK_SO}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
elseif(EXISTS "${WEBSPACE_ADBLOCK_SO}")
  install(FILES "${WEBSPACE_ADBLOCK_SO}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# The built-in Tor (TOR-027), at lib/tor/ beside the executable.
include("${CMAKE_CURRENT_SOURCE_DIR}/tor_bundle.cmake")
if(FLUTTER_TARGET_PLATFORM MATCHES "arm64$" OR
   (NOT FLUTTER_TARGET_PLATFORM AND CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64"))
  set(WEBSPACE_TOR_ARCH "arm64")
else()
  set(WEBSPACE_TOR_ARCH "x64")
endif()
# The archive is kept in the project's build directory, which the debug and
# release trees share.
webspace_bundle_tor("${WEBSPACE_TOR_ARCH}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../build/tor_bundle"
  "${INSTALL_BUNDLE_LIB_DIR}/tor")

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# The desktop entry, metainfo and icon, written with the application id and
# installed at the paths a desktop reads under a data directory, so a package
# copies the bundle's share/ into /usr/share, ~/.local/share or its own.
# Running update-desktop-database on applications/ then routes webspace:// to
# the app (LIR-004).
string(REGEX REPLACE "\\.[^.]*$" "" DEVELOPER_ID "${APPLICATION_ID}")
configure_file(webspace.desktop.in "${APPLICATION_ID}.desktop" @ONLY)
configure_file(webspace.metainfo.xml.in "${APPLICATION_ID}.metainfo.xml" @ONLY)
set(INSTALL_BUNDLE_SHARE_DIR "${CMAKE_INSTALL_PREFIX}/share")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${APPLICATION_ID}.desktop"
  DESTINATION "${INSTALL_BUNDLE_SHARE_DIR}/applications"
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${APPLICATION_ID}.metainfo.xml"
  DESTINATION "${INSTALL_BUNDLE_SHARE_DIR}/metainfo"
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../assets/webspace_icon_round.png"
  DESTINATION "${INSTALL_BUNDLE_SHARE_DIR}/icons/hicolor/512x512/apps"
  RENAME "${APPLICATION_ID}.png"
  COMPONENT Runtime)
