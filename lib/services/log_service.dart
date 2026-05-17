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
      if (kDebugMode) {
        debugPrint('[${entry.tag}/${entry.level.name}] ${entry.message}');
      }
    }
    notifyListeners();
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

  void clear() {
    _entries.clear();
    _sensitiveEntries.clear();
    notifyListeners();
  }
}
