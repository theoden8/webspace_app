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
  // Rung 2: a type parameter cannot be bounded away from List.
  assert(
    <T>[] is! List<List<Object?>>,
    'a stored list loads as a List<Object?>; read it with readPrefStrings',
  );
  final value = prefs.get(key);
  return value is T ? value : null;
}

/// The string list stored under [key], else null.
///
/// A launch loads a stored list from the platform as a `List<Object?>`,
/// which only `getStringList` casts, so `readPrefAs<List<String>>` reads it
/// as absent. A list holding anything but strings is null, as `readPrefAs`
/// reads a value of another type.
List<String>? readPrefStrings(SharedPreferences prefs, {required String key}) =>
    switch (prefs.get(key)) {
      final List<Object?> list when list.every((e) => e is String) =>
        List.unmodifiable(list.cast<String>()),
      _ => null,
    };
