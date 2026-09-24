import 'package:shared_preferences/shared_preferences.dart';

/// The stored value of [key] when it is a [T], else null.
///
/// The typed `SharedPreferences` getters throw on a value of another type,
/// and from v0.2.2 through v0.3.1 an import stored each `globalPrefs` value
/// under whatever type the backup file gave it. A device that once imported
/// a hand-edited file can hold a String under a key read with `getBool`;
/// read at startup through the getter, that throws before the sites load.
/// Every read of a `kExportedAppPrefs` key goes through here (gated by
/// `test/js/prefs_key_history.test.js`).
T? readPrefAs<T>(SharedPreferences prefs, String key) {
  final value = prefs.get(key);
  return value is T ? value : null;
}
