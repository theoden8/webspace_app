import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/site_suggestion.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/webspace_model.dart';

/// What the page saves beside its sites: the theme, the global user scripts,
/// the suggested sites, the webspaces, and which webspace and site were on
/// screen.
class ShellStore {
  ShellStore(this._sites);

  final SiteRuntime _sites;

  AppThemeSettings theme = const AppThemeSettings();
  List<UserScriptConfig> globalUserScripts = [];
  List<SiteSuggestion> suggestedSites = [];

  /// Reads the theme, carrying over the two formats before it.
  void loadTheme(SharedPreferences prefs) {
    final savedThemeSettings = readPrefAs<int>(prefs, key: 'themeSettings');
    if (savedThemeSettings != null) {
      theme = AppThemeSettings.fromStorageIndex(savedThemeSettings);
    } else {
      // Try to migrate from old appTheme format
      final savedAppTheme = readPrefAs<int>(prefs, key: 'appTheme');
      if (savedAppTheme != null && savedAppTheme < AppTheme.values.length) {
        theme = AppTheme.values[savedAppTheme].settings;
      } else {
        // Migrate from old themeMode if exists
        final oldThemeMode = readPrefAs<int>(prefs, key: 'themeMode');
        if (oldThemeMode != null) {
          // Map old ThemeMode to new settings (assuming green was the old color)
          switch (oldThemeMode) {
            case 0: // ThemeMode.system
              theme = AppThemeSettings(themeMode: ThemeMode.system, accentColor: AccentColor.green);
              break;
            case 1: // ThemeMode.light
              theme = AppThemeSettings(themeMode: ThemeMode.light, accentColor: AccentColor.green);
              break;
            case 2: // ThemeMode.dark
              theme = AppThemeSettings(themeMode: ThemeMode.dark, accentColor: AccentColor.green);
              break;
            default:
              theme = const AppThemeSettings();
          }
        }
      }
    }
  }

  Future<void> saveCurrentIndex() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('currentIndex', _sites.current == null ? 10000 : _sites.current!);
  }

  Future<void> saveTheme() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('themeSettings', theme.toStorageIndex());
  }

  Future<void> saveGlobalUserScripts() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final json = globalUserScripts.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('globalUserScripts', json);
  }

  Future<void> loadGlobalUserScripts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final json = prefs.getStringList('globalUserScripts');
    if (json == null) return;
    final loaded = <UserScriptConfig>[];
    for (var i = 0; i < json.length; i++) {
      try {
        loaded.add(UserScriptConfig.fromJson(
          jsonDecode(json[i]) as Map<String, dynamic>,
        ));
      } catch (e) {
        LogTag.boot.warning(
            'Skipped malformed global user script at index $i: $e');
      }
    }
    globalUserScripts = loaded;
  }

  /// Migrate pre-opt-in data: older builds ran every enabled global script
  /// on every site. After switching to per-site opt-in, sites that haven't
  /// declared [WebViewModel.enabledGlobalScriptIds] would silently lose
  /// their global scripts. For each site with an empty opt-in set, opt it
  /// into all currently-defined globals once. A marker key prevents this
  /// running again after the user starts curating per-site opt-ins. True
  /// when it ran, and the sites need saving.
  Future<bool> migrateGlobalScriptOptIn() async {
    if (globalUserScripts.isEmpty || _sites.models.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('globalUserScriptsOptInMigrated') == true) return false;
    final allIds = globalUserScripts.map((s) => s.id).toSet();
    for (final model in _sites.models) {
      if (model.enabledGlobalScriptIds.isEmpty) {
        model.enabledGlobalScriptIds = {...allIds};
      }
    }
    await prefs.setBool('globalUserScriptsOptInMigrated', true);
    return true;
  }

  Set<String> get archivedSiteIds => {
        for (final m in _sites.models)
          if (m.isArchiveTier) m.siteId,
      };

  Future<void> saveWebspaces() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Archive-tier collections and archived siteIds live in `_sites.webspaces`
    // for rendering while open but must not enter app-tier persistence
    // (the archive's own encrypted state carries them).
    List<String> webspacesJson = ArchiveMembershipEngine.persistable(
      _sites.webspaces,
      archivedSiteIds: archivedSiteIds,
    ).map((webspace) => jsonEncode(webspace.toJson())).toList();
    await prefs.setStringList('webspaces', webspacesJson);
  }

  Future<void> saveSelectedWebspaceId() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_sites.selectedWebspaceId != null) {
      await prefs.setString('selectedWebspaceId', _sites.selectedWebspaceId!);
    } else {
      await prefs.remove('selectedWebspaceId');
    }
  }

  /// Reads the webspaces into the runtime, "All" first.
  Future<void> loadWebspaces() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? webspacesJson = prefs.getStringList('webspaces');

    if (webspacesJson != null) {
      final loadedWebspaces = <Webspace>[];
      for (var i = 0; i < webspacesJson.length; i++) {
        try {
          loadedWebspaces.add(Webspace.fromJson(jsonDecode(webspacesJson[i])));
        } catch (e) {
          LogTag.boot.warning('Skipped malformed webspace at index $i: $e');
        }
      }

      _sites.webspaces.addAll(loadedWebspaces);
    }

    _ensureAllWebspaceExists();

    _sites.selectedWebspaceId = prefs.getString('selectedWebspaceId');

    if (_sites.selectedWebspaceId == null) {
      _sites.selectedWebspaceId = kAllWebspaceId;
    }
  }

  void _ensureAllWebspaceExists() {
    final hasAll = _sites.webspaces.any((ws) => ws.id == kAllWebspaceId);

    if (!hasAll) {
      _sites.webspaces.insert(0, Webspace.all());
    } else {
      // Ensure "All" is at the beginning
      final allIndex = _sites.webspaces.indexWhere((ws) => ws.id == kAllWebspaceId);
      if (allIndex > 0) {
        final allWebspace = _sites.webspaces.removeAt(allIndex);
        _sites.webspaces.insert(0, allWebspace);
      }
    }
  }
}
