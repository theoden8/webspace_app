import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The unread counts a background wake compares against (NOTIF-014), kept
/// past the process. iOS terminates a suspended app freely and launches it
/// again for the next refresh task, and a baseline held only in memory made
/// every such wake the first, which posts nothing.
///
/// Callers pass only sites whose baseline may outlive the process: never an
/// incognito site (nothing derived from it survives a restart), and never an
/// archive-tier one, which never reaches a wake (ARCH-001).
class WakeBaselineStore {
  static const String key = 'wakeUnreadBaselines';

  static Future<Map<String, int>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.get(key);
    if (raw is! String) return const {};
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};
    return {
      for (final e in decoded.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
  }

  static Future<void> write(Map<String, int> baselines) async {
    final prefs = await SharedPreferences.getInstance();
    if (baselines.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(baselines));
    }
  }
}
