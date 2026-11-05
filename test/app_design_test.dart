import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/app_design.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/library_layout.dart';

/// WEBSPACE-019: the first launch that knows Legacy design decides it once
/// from what the device holds, and leaving it starts the library at its own
/// layouts.
void main() {
  tearDown(() {
    isDemoMode = false;
    for (final pref in [
      AppPref.libraryWebspaceLayout,
      AppPref.libraryLayout,
    ]) {
      pref.debugValue = pref.fallback;
    }
    AppPref.legacyDesign.debugValue = AppPref.legacyDesign.fallback;
  });

  /// The design a launch settles on for a device that holds [stored], and
  /// what it leaves stored.
  Future<(bool, Object?)> launch(Map<String, Object> stored) async {
    SharedPreferences.setMockInitialValues(stored);
    final prefs = await SharedPreferences.getInstance();
    AppPref.loadAll(prefs);
    await loadLegacyDesign(prefs);
    return (AppPref.legacyDesign.value, prefs.get(AppPref.legacyDesign.key));
  }

  test('WEBSPACE-019 a new install starts in the library and keeps it once '
      'it saves sites', () async {
    expect(await launch({}), (false, false));
    final prefs = await SharedPreferences.getInstance();
    expect(await launch({
      ...{for (final k in prefs.getKeys()) k: prefs.get(k)!},
      'webViewModels': ['{}'],
      'webspaces': ['{}'],
    }), (false, false));
  });

  for (final key in ['webViewModels', 'webspaces']) {
    test('WEBSPACE-019 a device an earlier build saved $key on keeps the '
        'legacy design', () async {
      expect(await launch({key: ['{}']}), (true, true));
    });
  }

  test('WEBSPACE-019 a device that ran Alternative design keeps the library',
      () async {
    final ran = {
      'webViewModels': ['{}'],
      AppPref.developerMode.key: true,
      'experimentalFolderLibrary': true,
    };
    expect(await launch(ran), (false, false));
    expect(await launch({...ran, AppPref.developerMode.key: false}),
        (true, true),
        reason: 'the switch counted only with developer mode on');
    expect(await launch({...ran, 'experimentalFolderLibrary': 'yes'}),
        (true, true),
        reason: 'a wrong-typed switch reads as off');
  });

  test('WEBSPACE-019 a stored choice is never decided again', () async {
    expect(
        await launch({'webViewModels': ['{}'], AppPref.legacyDesign.key: false}),
        (false, false));
    expect(await launch({AppPref.legacyDesign.key: true}), (true, true));
  });

  test('WEBSPACE-019 demo mode decides without writing', () async {
    isDemoMode = true;
    expect(await launch({'webViewModels': ['{}']}), (true, null));
  });

  test('WEBSPACE-019 leaving Legacy design starts the library at a list of '
      'webspaces and Automatic folders; entering it leaves them', () async {
    SharedPreferences.setMockInitialValues({});
    AppPref.libraryWebspaceLayout.debugValue = LibraryLayout.grid.name;
    AppPref.libraryLayout.debugValue = LibraryLayout.list.name;
    await chooseLegacyDesign(on: true);
    expect(AppPref.legacyDesign.value, isTrue);
    expect(AppPref.libraryWebspaceLayout.value, LibraryLayout.grid.name);
    expect(AppPref.libraryLayout.value, LibraryLayout.list.name);

    await chooseLegacyDesign(on: false);
    expect(AppPref.legacyDesign.value, isFalse);
    expect(LibraryLayout.of(AppPref.libraryWebspaceLayout.value),
        LibraryLayout.list);
    expect(LibraryLayout.of(AppPref.libraryLayout.value), LibraryLayout.auto);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.legacyDesign.key), isFalse);
    expect(prefs.getString(AppPref.libraryWebspaceLayout.key), 'list');
    expect(prefs.getString(AppPref.libraryLayout.key), 'auto');
  });

  test('WEBSPACE-019 a new install shows its webspaces as a list and its '
      'folders Automatic', () {
    expect(AppPref.legacyDesign.fallback, isFalse);
    expect(LibraryLayout.of(AppPref.libraryWebspaceLayout.fallback),
        LibraryLayout.list);
    expect(LibraryLayout.of(AppPref.libraryLayout.fallback),
        LibraryLayout.auto);
  });
}
