import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/file_dialog.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/widgets/toast.dart';

/// One log line as the App Logs and Background tabs show it: coloured by
/// level, with sensitive entries marked and edged so they are never mistaken
/// for ones that may be shared.
class LogEntryLine extends StatelessWidget {
  const LogEntryLine({super.key, required this.entry, required this.time});

  final LogEntry entry;
  final String time;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final color = switch (entry.level) {
      LogLevel.warning => scheme.warning,
      LogLevel.error => scheme.error,
      LogLevel.info => dark ? Colors.lightBlue.shade200 : Colors.blue.shade800,
      LogLevel.debug =>
        Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white,
    };
    final isSensitive = entry.sensitivity == LogSensitivity.sensitive;
    final prefix = isSensitive ? '[SENSITIVE] ' : '';
    final line =
        '[$time] [${entry.level.name}] $prefix[${entry.tag}] ${entry.message}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 1.0),
      decoration: isSensitive
          ? BoxDecoration(
              border: Border(
                left: BorderSide(color: Colors.deepOrange.shade400, width: 3),
              ),
            )
          : null,
      child: SelectableText(
        line,
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: color),
      ),
    );
  }
}

/// Saves [text] as `<prefix>_<timestamp>.txt` through the platform save
/// dialog and confirms with a snackbar. Callers pass only what may leave the
/// device: no sensitive entry is ever written to a file.
Future<void> saveLogText(
  BuildContext context, {
  required String text,
  required String fileNamePrefix,
}) async {
  if (text.isEmpty) return;
  final loc = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final bytes = utf8.encode(text);
  final timestamp =
      DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
  final fileName = '${fileNamePrefix}_$timestamp.txt';

  final outputPath = await FileDialog.saveFile(
    dialogTitle: loc.devToolsExportLogsDialogTitle,
    fileName: fileName,
    bytes: bytes,
    mimeType: 'text/plain',
  );

  if (outputPath == null) return;
  messenger.toast(loc.devToolsLogsExported);
}
