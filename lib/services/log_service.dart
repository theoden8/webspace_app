import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final String tag;
  final String message;
  final LogLevel level;

  LogEntry({
    required this.timestamp,
    required this.tag,
    required this.message,
    required this.level,
  });
}

class LogService extends ChangeNotifier {
  static final instance = LogService._();
  LogService._();

  final List<LogEntry> _entries = [];
  static const maxEntries = 2000;

  void log(String tag, String message, {LogLevel level = LogLevel.debug}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      tag: tag,
      message: message,
      level: level,
    );
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    if (kDebugMode) {
      debugPrint('[${entry.tag}/${entry.level.name}] ${entry.message}');
    }
    notifyListeners();
  }

  List<LogEntry> get entries => List.unmodifiable(_entries);

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
    notifyListeners();
  }
}
