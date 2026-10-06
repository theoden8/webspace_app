import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

/// The iOS and Android half of the background log: a file the native plugins
/// write to themselves, so a step the OS runs while no Dart is alive (an
/// Android worker that finds no engine, an iOS refresh task that expires) is
/// still on record the next time the app is opened. Dart's own entries are
/// appended to the same file, which keeps one order and one size cap.
///
/// Nothing that names a site crosses this seam: the file is plain text on
/// disk, and the native side has no site data to add.
abstract class BackgroundLogNative {
  bool get available;

  /// On creates the file, off deletes it. The file is the switch the native
  /// side reads, so a worker in a process Dart never started records exactly
  /// when developer mode is on.
  Future<void> setEnabled(bool enabled);

  Future<void> append(LogEntry entry);

  /// Null when the file could not be read; the caller falls back to what
  /// this process recorded.
  Future<List<LogEntry>?> read();

  Future<void> clear();

  /// Ordered `(name, value)` rows describing the OS gates a background
  /// refresh and a notification depend on.
  Future<List<MapEntry<String, String>>> systemState();
}

class MethodChannelBackgroundLogNative implements BackgroundLogNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/background_task');

  @override
  bool get available => hostIsIOS || hostIsAndroid;

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      LogService.instance.log('BackgroundLog', '$method failed: ${e.message}',
          level: LogLevel.warning);
    } on MissingPluginException {
      LogService.instance.log('BackgroundLog', '$method: no native handler',
          level: LogLevel.warning);
    }
    return null;
  }

  @override
  Future<void> setEnabled(bool enabled) =>
      _invoke<void>('setBackgroundLogEnabled', {'enabled': enabled});

  @override
  Future<void> append(LogEntry entry) => _invoke<void>('appendBackgroundLog', {
        't': entry.timestamp.millisecondsSinceEpoch,
        'level': entry.level.name,
        'tag': entry.tag,
        'message': entry.message,
      });

  @override
  Future<List<LogEntry>?> read() async {
    final lines = await _invoke<List<Object?>>('readBackgroundLog');
    if (lines == null) return null;
    return [
      for (final line in lines)
        if (line is String) ?parseBackgroundLogLine(line),
    ];
  }

  @override
  Future<void> clear() => _invoke<void>('clearBackgroundLog');

  @override
  Future<List<MapEntry<String, String>>> systemState() async {
    final rows = await _invoke<List<Object?>>('backgroundSystemState');
    return [
      for (final row in rows ?? const <Object?>[])
        if (row is List && row.length == 2 && row[0] is String && row[1] is String)
          MapEntry(row[0] as String, row[1] as String),
    ];
  }
}

/// One line of the native file: a JSON object with `t` (epoch ms), `l`
/// (level), `g` (tag) and `m` (message). A line that does not parse is dropped rather than shown
/// half-read; the file is rewritten by two writers across app versions.
LogEntry? parseBackgroundLogLine(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final t = decoded['t'];
  final g = decoded['g'];
  final m = decoded['m'];
  if (t is! int || g is! String || m is! String) return null;
  final l = decoded['l'];
  return LogEntry(
    timestamp: DateTime.fromMillisecondsSinceEpoch(t),
    tag: g,
    message: m,
    level: LogLevel.values.firstWhere((v) => v.name == l,
        orElse: () => LogLevel.info),
  );
}

/// DEVTOOLS-011: what happened while the app was in the background, kept
/// across process death so the user can read it on the device that missed a
/// notification, without logcat or Console.app.
///
/// Records only while developer mode is on ([setRecording]); turning it off
/// deletes the log. Every entry is also forwarded to [LogService], so the App
/// Logs tab keeps seeing the same lines it always did.
///
/// Sensitive content stays separate, as in [LogService]: the `sensitive`
/// companion of an entry (site names, siteIds, page titles, notification text)
/// lives in a memory ring here and never reaches the native file, an export,
/// or the clipboard without a confirmation. The normal entry refers to sites
/// by position and count only.
class BackgroundLog extends ChangeNotifier {
  BackgroundLog({BackgroundLogNative? native})
      : _native = native ?? MethodChannelBackgroundLogNative();

  static final BackgroundLog instance = BackgroundLog();

  static const int maxEntries = 400;

  /// A wake records a line per site in quick succession. A view that re-reads
  /// the file on every change waits this long for the burst to end.
  static const Duration burstQuiet = Duration(milliseconds: 300);

  final BackgroundLogNative _native;
  final List<LogEntry> _entries = [];
  final List<LogEntry> _sensitive = [];
  bool _recording = false;

  bool get recording => _recording;

  /// App-side rows for [systemState] that only the page state knows (how
  /// many notification sites are loaded). Set by the home page.
  List<MapEntry<String, String>> Function()? appState;

  /// Called on every startup and on every developer-mode flip, so the native
  /// switch always matches the pref, including after a settings import.
  Future<void> setRecording(bool on) async {
    final changed = _recording != on;
    _recording = on;
    if (!on) {
      _entries.clear();
      _sensitive.clear();
    }
    if (_native.available) await _native.setEnabled(on);
    if (changed) notifyListeners();
  }

  void record(
    String tag,
    String message, {
    LogLevel level = LogLevel.info,
    String? sensitive,
  }) {
    LogService.instance.log(tag, message, level: level);
    if (sensitive != null) {
      LogService.instance.log(tag, sensitive,
          level: level, sensitivity: LogSensitivity.sensitive);
    }
    if (!_recording) return;
    final now = DateTime.now();
    final entry =
        LogEntry(timestamp: now, tag: tag, message: message, level: level);
    _push(_entries, entry);
    if (sensitive != null) {
      _push(
          _sensitive,
          LogEntry(
            timestamp: now,
            tag: tag,
            message: sensitive,
            level: level,
            sensitivity: LogSensitivity.sensitive,
          ));
    }
    if (_native.available) unawaited(_native.append(entry));
    notifyListeners();
  }

  static void _push(List<LogEntry> ring, LogEntry e) {
    ring.add(e);
    if (ring.length > maxEntries) ring.removeAt(0);
  }

  /// Oldest first. On iOS and Android the normal entries come from the native
  /// file, which holds earlier processes and native-only steps; elsewhere,
  /// or when the file cannot be read, from this process.
  Future<List<LogEntry>> entries({required bool includeSensitive}) async {
    final stored = _native.available ? await _native.read() : null;
    final normal = stored ?? List<LogEntry>.of(_entries);
    final all = [...normal, if (includeSensitive) ..._sensitive];
    final order = {for (var i = 0; i < all.length; i++) all[i]: i};
    all.sort((a, b) {
      final byTime = a.timestamp.compareTo(b.timestamp);
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
    return all;
  }

  Future<List<MapEntry<String, String>>> systemState() async => [
        ...?appState?.call(),
        if (_native.available) ...await _native.systemState(),
      ];

  Future<void> clear() async {
    _entries.clear();
    _sensitive.clear();
    if (_native.available) await _native.clear();
    notifyListeners();
  }

  /// Text for a file or the clipboard. Sensitive entries are dropped unless
  /// [includeSensitive]; a file is never written with them.
  static String format(
    Iterable<LogEntry> entries, {
    bool includeSensitive = false,
  }) {
    final buffer = StringBuffer();
    for (final e in entries) {
      if (!includeSensitive && e.sensitivity == LogSensitivity.sensitive) {
        continue;
      }
      buffer.writeln(
          '[${formatTimestamp(e.timestamp)}] [${e.tag}/${e.level.name}] ${e.message}');
    }
    return buffer.toString();
  }

  /// The background log spans days, so its lines carry the date.
  static String formatTimestamp(DateTime t) =>
      '${t.year}-${formatShortTimestamp(t)}';

  /// On screen the year is width a phone line cannot spare.
  static String formatShortTimestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _sensitive.clear();
    _recording = false;
    appState = null;
  }
}
