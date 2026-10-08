import 'package:shared_preferences/shared_preferences.dart';

/// The stored value of [key] when it is a [T], else null.
///
/// The typed `SharedPreferences` getters throw on a value of another type,
/// and from v0.2.2 through v0.3.1 an import stored each `globalPrefs` value
/// under whatever type the backup file gave it. A device that once imported
/// a hand-edited file can hold a String under a key read with `getBool`;
/// read at startup through the getter, that throws before the sites load.
/// `AppPref.stored` does the same for every registered pref.
T? readPrefAs<T>(SharedPreferences prefs, {required String key}) {
  final value = prefs.get(key);
  return value is T ? value : null;
}
