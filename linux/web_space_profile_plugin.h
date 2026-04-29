// web_space_profile_plugin.h
//
// Per-site Profile API plugin for the Linux runner. Linux counterpart
// of android/.../WebSpaceProfilePlugin.kt and shared/WebSpaceProfilePlugin.swift.
//
// Each WebViewModel.siteId maps to a persistent WebKitNetworkSession
// whose dataDirectory and cacheDirectory live under a deterministic
// XDG path:
//
//   data:  $XDG_DATA_HOME/webspace/profiles/<profileName>/data
//   cache: $XDG_CACHE_HOME/webspace/profiles/<profileName>/cache
//
// where profileName == "ws-<siteId>".
//
// The bind itself happens inside the patched flutter_inappwebview_linux
// fork — the InAppWebView constructor passes the same path pair to
// `webkit_network_session_new()` when its `webspaceProfile` setting is
// non-empty (see third_party/flutter_inappwebview_linux.patch). This
// plugin handles the lifecycle Dart channel only:
//
//   - isSupported() — always TRUE on Linux when this plugin is wired in
//     (presence of the patched plugin implies WebKitNetworkSession 2.40+
//     support; the runtime check happens at compile time via
//     pkg_check_modules).
//   - getOrCreateProfile(siteId) — `mkdir -p` both directories so the
//     subsequent webkit_network_session_new() succeeds, then return
//     "ws-<siteId>".
//   - bindProfileToWebView(siteId) — no-op on Linux; the bind is at
//     WebKitWebView construction time (mirrors iOS/macOS).
//   - deleteProfile(siteId) — recursively rm both directories.
//   - listProfiles() — scan $XDG_DATA_HOME/webspace/profiles/ for
//     subdirectories matching `ws-<siteId>` and return the bare siteIds.

#ifndef WEB_SPACE_PROFILE_PLUGIN_H_
#define WEB_SPACE_PROFILE_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// Registers the WebSpace per-site profile MethodChannel handler on the
// supplied messenger. The plugin owns no state beyond the channel
// itself; pass the Flutter view's binary messenger.
void web_space_profile_plugin_register(FlBinaryMessenger* messenger);

G_END_DECLS

#endif  // WEB_SPACE_PROFILE_PLUGIN_H_
