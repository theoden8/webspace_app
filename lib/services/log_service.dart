import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warning, error }

/// Whether an entry may carry per-site identifiers (siteId, container
/// names, cookie hostnames, URLs, page titles, proxy passwords, etc.).
/// `sensitive` entries are kept in a memory-only ring, never written
/// to disk, never piped to `debugPrint`, and only surfaced in the
/// in-app dev-tools log view when the runtime toggle is on.
enum LogSensitivity { normal, sensitive }

class LogEntry {
  final DateTime timestamp;
  final String tag;
  final String message;
  final LogLevel level;
  final LogSensitivity sensitivity;

  LogEntry({
    required this.timestamp,
    required this.tag,
    required this.message,
    required this.level,
    this.sensitivity = LogSensitivity.normal,
  });
}

class LogService extends ChangeNotifier {
  static final instance = LogService._();
  LogService._();

  final List<LogEntry> _entries = [];
  final List<LogEntry> _sensitiveEntries = [];
  static const maxEntries = 2000;

  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _sensitiveEntries.clear();
    notifyListeners();
  }

  void log(
    String tag,
    String message, {
    LogLevel level = LogLevel.debug,
    LogSensitivity sensitivity = LogSensitivity.normal,
  }) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      tag: tag,
      message: message,
      level: level,
      sensitivity: sensitivity,
    );
    if (sensitivity == LogSensitivity.sensitive) {
      _sensitiveEntries.add(entry);
      if (_sensitiveEntries.length > maxEntries) {
        _sensitiveEntries.removeAt(0);
      }
    } else {
      _entries.add(entry);
      if (_entries.length > maxEntries) {
        _entries.removeAt(0);
      }
      // Not release: a shipped build keeps its log ring in memory for Dev
      // Tools and puts nothing in logcat. Profile is in scope because the
      // adb tiers read these lines out of logcat, and profile is the build
      // mode that gets them an AOT, non-inspectable webview.
      if (!kReleaseMode) {
        debugPrint('[${entry.tag}/${entry.level.name}] ${entry.message}');
      }
    }
    notifyListeners();
  }

  /// The most recent entries carrying one of [tags], oldest first.
  ///
  /// Walks backwards through both rings instead of merging and sorting
  /// them: this feeds a live view that rebuilds on every new entry, and
  /// sorting 2000 of them per line is not that. [scan] bounds the walk so a
  /// quiet tag cannot make the cost the size of the ring.
  List<LogEntry> recent(Set<String> tags, {int limit = 6, int scan = 400}) {
    final out = <LogEntry>[];
    var i = _entries.length - 1;
    var j = _sensitiveEntries.length - 1;
    var seen = 0;
    while (out.length < limit && seen < scan && (i >= 0 || j >= 0)) {
      final a = i >= 0 ? _entries[i] : null;
      final b = j >= 0 ? _sensitiveEntries[j] : null;
      final LogEntry next;
      if (a == null) {
        next = b!;
        j--;
      } else if (b == null) {
        next = a;
        i--;
      } else if (a.timestamp.isAfter(b.timestamp)) {
        next = a;
        i--;
      } else {
        next = b;
        j--;
      }
      seen++;
      if (tags.contains(next.tag)) out.add(next);
    }
    return out.reversed.toList();
  }

  List<LogEntry> get entries => List.unmodifiable(_entries);
  List<LogEntry> get sensitiveEntries => List.unmodifiable(_sensitiveEntries);

  /// Combined view of normal + sensitive entries, ordered by timestamp.
  /// Used by the dev-tools UI when the "show sensitive" toggle is on.
  List<LogEntry> get allEntriesMerged {
    final combined = <LogEntry>[..._entries, ..._sensitiveEntries];
    combined.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return List.unmodifiable(combined);
  }

  /// Export only ships normal entries; sensitive entries never reach
  /// a file the user can share or that ends up syncing off-device.
  String export() {
    final buffer = StringBuffer();
    for (final entry in _entries) {
      final time = '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
          '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
          '${entry.timestamp.second.toString().padLeft(2, '0')}';
      buffer.writeln('[$time] [${entry.tag}/${entry.level.name}] ${entry.message}');
    }
    return buffer.toString();
  }

  /// Format an arbitrary set of entries for the clipboard. Sensitive entries
  /// are dropped unless [includeSensitive] is set: the system clipboard syncs
  /// off-device (Android clipboard history, cloud clipboard, third-party
  /// keyboards), so the caller must have confirmed that with the user first.
  /// Files written by [export] never carry them at all.
  static String formatForClipboard(
    Iterable<LogEntry> entries, {
    bool includeSensitive = false,
  }) {
    final buffer = StringBuffer();
    for (final entry in entries) {
      if (!includeSensitive && entry.sensitivity == LogSensitivity.sensitive) {
        continue;
      }
      final time = '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
          '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
          '${entry.timestamp.second.toString().padLeft(2, '0')}';
      buffer.writeln('[$time] [${entry.tag}/${entry.level.name}] ${entry.message}');
    }
    return buffer.toString();
  }

  void clear() {
    _entries.clear();
    _sensitiveEntries.clear();
    notifyListeners();
  }
}
