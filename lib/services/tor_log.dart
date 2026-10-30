// How a line of tor's log, or a runtime's note about tor, reaches the app
// log (TOR-018): the Apple plugin's log channel and the Linux runtime's
// child process both end here, so the tag and the sensitivity are decided
// once.

import 'package:webspace/services/log_service.dart';

/// One line of tor's own log, or one of the runtime's lifecycle notes.
class TorLogLine {
  const TorLogLine({
    required this.fromTor,
    required this.level,
    required this.message,
  });

  /// Whether tor wrote this. The runtime's own notes cover the window tor
  /// cannot describe: before its control port answers, and after it goes.
  final bool fromTor;
  final LogLevel level;
  final String message;
}

/// [line] in the app log.
void logTorLine(TorLogLine line) {
  LogService.instance.log(
    line.fromTor ? LogTag.torLog : LogTag.tor,
    message: line.message,
    level: line.level,
    // tor's own output is sensitive and the runtime's notes are not. A
    // notice-level line can name the bridges this device dials (TOR-017)
    // and the relays it picked, so it belongs in the memory-only ring that
    // Dev Tools only shows on request; the notes carry nothing but the
    // runtime's own state machine.
    sensitivity:
        line.fromTor ? LogSensitivity.sensitive : LogSensitivity.normal,
  );
}

/// One line tor wrote to its log, `Oct 30 10:56:07.829 [notice] Opening
/// Socks listener on 127.0.0.1:0`, without the timestamp: every entry in the
/// app log carries one already. A line in no other shape is kept whole.
TorLogLine parseTorLogLine(String line) {
  final match = RegExp(r'\[(\w+)\]\s*(.*)$').firstMatch(line);
  final message = match?.group(2) ?? '';
  return TorLogLine(
    fromTor: true,
    level: switch (match?.group(1)) {
      'err' => LogLevel.error,
      'warn' => LogLevel.warning,
      _ => LogLevel.info,
    },
    message: message.isEmpty ? line : message,
  );
}
