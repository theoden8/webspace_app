// web_space_profile_plugin.cc — see header for design notes.
//
// Path convention (DUPLICATED in third_party/flutter_inappwebview_linux.patch
// at InAppWebView constructor) — kept in sync by hand because the patched
// plugin and this runner-side handler each do their own filesystem ops.
// If you change either one, change both.

#include "web_space_profile_plugin.h"

#include <gio/gio.h>
#include <glib.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr const char* kChannelName =
    "org.codeberg.theoden8.webspace/profile";
constexpr const char* kProfileDirNamespace = "webspace";
constexpr const char* kProfilesSubdir = "profiles";
constexpr const char* kProfileNamePrefix = "ws-";

// Fully-qualified profile name written to the directory tree and
// returned to Dart. Mirrors the iOS/macOS/Android convention so the
// engine layer compares profile names by-string identically across
// platforms.
std::string ProfileNameForSiteId(const std::string& siteId) {
  return std::string(kProfileNamePrefix) + siteId;
}

std::string ProfileDataDir(const std::string& profileName) {
  g_autofree gchar* path = g_build_filename(
      g_get_user_data_dir(), kProfileDirNamespace, kProfilesSubdir,
      profileName.c_str(), "data", nullptr);
  return std::string(path);
}

std::string ProfileCacheDir(const std::string& profileName) {
  g_autofree gchar* path = g_build_filename(
      g_get_user_cache_dir(), kProfileDirNamespace, kProfilesSubdir,
      profileName.c_str(), "cache", nullptr);
  return std::string(path);
}

std::string ProfilesRoot() {
  g_autofree gchar* path = g_build_filename(
      g_get_user_data_dir(), kProfileDirNamespace, kProfilesSubdir, nullptr);
  return std::string(path);
}

// Recursively delete a directory tree. GLib has no helper, so use GIO's
// GFile enumeration. Returns true on success or if the path does not
// exist (idempotent — matches Android/iOS semantics).
bool RemoveDirectoryRecursive(const std::string& path) {
  g_autoptr(GFile) file = g_file_new_for_path(path.c_str());
  if (!g_file_query_exists(file, nullptr)) {
    return true;
  }
  g_autoptr(GError) err = nullptr;
  GFileType type = g_file_query_file_type(
      file, G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, nullptr);
  if (type == G_FILE_TYPE_DIRECTORY) {
    g_autoptr(GFileEnumerator) enumerator = g_file_enumerate_children(
        file, G_FILE_ATTRIBUTE_STANDARD_NAME,
        G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, nullptr, &err);
    if (err != nullptr) {
      return false;
    }
    while (true) {
      g_autoptr(GFileInfo) info =
          g_file_enumerator_next_file(enumerator, nullptr, &err);
      if (info == nullptr) break;
      const char* child_name = g_file_info_get_name(info);
      g_autoptr(GFile) child = g_file_get_child(file, child_name);
      g_autofree gchar* child_path = g_file_get_path(child);
      if (!RemoveDirectoryRecursive(child_path)) {
        return false;
      }
    }
  }
  return g_file_delete(file, nullptr, nullptr) != FALSE;
}

bool ExtractSiteId(FlValue* args, std::string* out_site_id) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue* val = fl_value_lookup_string(args, "siteId");
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_STRING) {
    return false;
  }
  const char* str = fl_value_get_string(val);
  if (str == nullptr || *str == '\0') return false;
  *out_site_id = str;
  return true;
}

void ReplyError(FlMethodCall* call, const char* code, const char* message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
  fl_method_call_respond(call, response, nullptr);
}

void ReplySuccess(FlMethodCall* call, FlValue* result) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(call, response, nullptr);
}

void HandleIsSupported(FlMethodCall* call) {
  // The patched flutter_inappwebview_linux compiles only against
  // WebKitNetworkSession (libwpewebkit-2.0 >= 2.40). If we got linked,
  // the API is available — no runtime feature flag needed.
  g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
  ReplySuccess(call, result);
}

void HandleGetOrCreateProfile(FlMethodCall* call) {
  std::string site_id;
  if (!ExtractSiteId(fl_method_call_get_args(call), &site_id)) {
    ReplyError(call, "INVALID_ARGS", "siteId required");
    return;
  }
  std::string profile = ProfileNameForSiteId(site_id);
  // mkdir -p both dirs so the subsequent webkit_network_session_new()
  // call inside InAppWebView's constructor doesn't have to.
  // g_mkdir_with_parents returns 0 on success or if the directory
  // already existed.
  if (g_mkdir_with_parents(ProfileDataDir(profile).c_str(), 0700) != 0 ||
      g_mkdir_with_parents(ProfileCacheDir(profile).c_str(), 0700) != 0) {
    ReplyError(call, "MKDIR_FAILED",
               "Could not create profile directory tree");
    return;
  }
  g_autoptr(FlValue) result = fl_value_new_string(profile.c_str());
  ReplySuccess(call, result);
}

void HandleBindProfileToWebView(FlMethodCall* call) {
  // No-op on Linux. The bind is locked in at WebKitWebView construction
  // by the patched plugin via the `network-session` GObject property.
  // This method exists to keep the cross-platform Dart interface
  // uniform; the engine layer doesn't depend on the return value here.
  g_autoptr(FlValue) result = fl_value_new_int(0);
  ReplySuccess(call, result);
}

void HandleDeleteProfile(FlMethodCall* call) {
  std::string site_id;
  if (!ExtractSiteId(fl_method_call_get_args(call), &site_id)) {
    ReplyError(call, "INVALID_ARGS", "siteId required");
    return;
  }
  std::string profile = ProfileNameForSiteId(site_id);
  // Idempotent: missing dirs are not an error (matches Apple's
  // WKWebsiteDataStore.remove(forIdentifier:) and Android's
  // ProfileStore.deleteProfile semantics — orphan GC may call this
  // for siteIds whose data was already removed externally).
  bool data_ok = RemoveDirectoryRecursive(ProfileDataDir(profile));
  bool cache_ok = RemoveDirectoryRecursive(ProfileCacheDir(profile));
  if (!data_ok || !cache_ok) {
    ReplyError(call, "RM_FAILED",
               "Could not remove profile directory tree");
    return;
  }
  ReplySuccess(call, nullptr);
}

void HandleListProfiles(FlMethodCall* call) {
  // Scan $XDG_DATA_HOME/webspace/profiles/ for subdirectories whose
  // name starts with "ws-". Strip the prefix and return the bare
  // siteIds — matches the Android/iOS contract.
  std::vector<std::string> site_ids;
  std::string root = ProfilesRoot();
  g_autoptr(GFile) root_file = g_file_new_for_path(root.c_str());
  if (g_file_query_exists(root_file, nullptr)) {
    g_autoptr(GError) err = nullptr;
    g_autoptr(GFileEnumerator) enumerator = g_file_enumerate_children(
        root_file,
        G_FILE_ATTRIBUTE_STANDARD_NAME ","
        G_FILE_ATTRIBUTE_STANDARD_TYPE,
        G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, nullptr, &err);
    if (enumerator != nullptr) {
      const size_t prefix_len = std::strlen(kProfileNamePrefix);
      while (true) {
        g_autoptr(GFileInfo) info =
            g_file_enumerator_next_file(enumerator, nullptr, nullptr);
        if (info == nullptr) break;
        if (g_file_info_get_file_type(info) != G_FILE_TYPE_DIRECTORY) continue;
        const char* name = g_file_info_get_name(info);
        if (name == nullptr) continue;
        if (g_str_has_prefix(name, kProfileNamePrefix)) {
          site_ids.emplace_back(name + prefix_len);
        }
      }
    }
  }
  g_autoptr(FlValue) result = fl_value_new_list();
  for (const auto& id : site_ids) {
    fl_value_append_take(result, fl_value_new_string(id.c_str()));
  }
  ReplySuccess(call, result);
}

void OnMethodCall(FlMethodChannel* /*channel*/, FlMethodCall* call,
                  gpointer /*user_data*/) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "isSupported") == 0) {
    HandleIsSupported(call);
  } else if (g_strcmp0(method, "getOrCreateProfile") == 0) {
    HandleGetOrCreateProfile(call);
  } else if (g_strcmp0(method, "bindProfileToWebView") == 0) {
    HandleBindProfileToWebView(call);
  } else if (g_strcmp0(method, "deleteProfile") == 0) {
    HandleDeleteProfile(call);
  } else if (g_strcmp0(method, "listProfiles") == 0) {
    HandleListProfiles(call);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}

}  // namespace

void web_space_profile_plugin_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // The channel object outlives the call to register; Flutter holds the
  // ref via the message handler. Intentionally leaked (no g_object_unref):
  // the channel must stay alive for the lifetime of the runner. Same
  // pattern as auto-generated plugin registrants.
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, OnMethodCall, nullptr,
                                            nullptr);
}
