import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
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
    // Light shades for a dark background, deep ones for a light one: plain
    // amber on a light theme is close to unreadable.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Color color;
    switch (entry.level) {
      case LogLevel.warning:
        color = dark ? Colors.amber : Colors.orange.shade900;
      case LogLevel.error:
        color = dark ? Colors.red.shade300 : Colors.red.shade800;
      case LogLevel.info:
        color = dark ? Colors.lightBlue.shade200 : Colors.blue.shade800;
      case LogLevel.debug:
        color = Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white;
    }
    final isSensitive = entry.sensitivity == LogSensitivity.sensitive;
    final prefix = isSensitive ? '[SENSITIVE] ' : '';
    final line = '[$time] $prefix[${entry.tag}] ${entry.message}';
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
  BuildContext context,
  String text, {
  required String fileNamePrefix,
}) async {
  if (text.isEmpty) return;
  final loc = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final bytes = utf8.encode(text);
  final timestamp =
      DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
  final fileName = '${fileNamePrefix}_$timestamp.txt';

  final isMobile = hostIsIOS || hostIsAndroid;
  final outputPath = await FilePicker.saveFile(
    dialogTitle: loc.devToolsExportLogsDialogTitle,
    fileName: fileName,
    bytes: isMobile ? bytes : null,
  );

  if (outputPath != null && !isMobile) {
    final filePath =
        outputPath.endsWith('.txt') ? outputPath : '$outputPath.txt';
    await hostWriteFileText(filePath, text);
  }

  if (outputPath != null) {
    messenger.toast(loc.devToolsLogsExported);
  }
}
