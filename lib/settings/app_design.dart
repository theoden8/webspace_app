import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/pref_read.dart';

/// What a build before [AppPref.legacyDesign] saved: the sites
/// (`SiteListStore`), the webspaces (`ShellStore`), and the Alternative
/// design experiment's switch, which developer mode gated.
const String _sitesKey = 'webViewModels';
const String _webspacesKey = 'webspaces';
const String _alternativeDesignKey = 'experimentalFolderLibrary';

/// Loads [AppPref.legacyDesign], deciding it once on the first launch that
/// knows it (WEBSPACE-019): a device that saved a site or a webspace under an
/// earlier build keeps the design that build showed, the legacy one unless
/// developer mode and Alternative design were both on; any other starts in
/// the library.
Future<void> loadLegacyDesign(SharedPreferences prefs) async {
  if (prefs.containsKey(AppPref.legacyDesign.key)) {
    AppPref.legacyDesign.load(prefs);
    return;
  }
  final ranBefore =
      prefs.containsKey(_sitesKey) || prefs.containsKey(_webspacesKey);
  final ranLibrary = AppPref.developerMode.stored(prefs) &&
      readPrefAs<bool>(prefs, key: _alternativeDesignKey) == true;
  await AppPref.legacyDesign.set(ranBefore && !ranLibrary);
}

/// Sets [AppPref.legacyDesign]. Leaving the legacy design starts the library
/// at its own layouts, the webspaces a list and each webspace's sites
/// Automatic, whatever they were left at (WEBSPACE-019).
Future<void> chooseLegacyDesign({required bool on}) async {
  if (!on) {
    for (final layout in [
      AppPref.libraryWebspaceLayout,
      AppPref.libraryLayout,
    ]) {
      await layout.set(layout.fallback);
    }
  }
  await AppPref.legacyDesign.set(on);
}
