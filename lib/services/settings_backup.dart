import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// Backup version for compatibility checking
const int kBackupVersion = 1;

/// Data class representing a backup of app settings
class SettingsBackup {
  final int version;
  final List<Map<String, dynamic>> sites;
  final List<Map<String, dynamic>> webspaces;
  final int themeMode;
  final bool showUrlBar;
  final String? selectedWebspaceId;
  final int? currentIndex;
  final DateTime exportedAt;

  SettingsBackup({
    required this.version,
    required this.sites,
    required this.webspaces,
    required this.themeMode,
    required this.showUrlBar,
    this.selectedWebspaceId,
    this.currentIndex,
    required this.exportedAt,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'sites': sites,
        'webspaces': webspaces,
        'themeMode': themeMode,
        'showUrlBar': showUrlBar,
        'selectedWebspaceId': selectedWebspaceId,
        'currentIndex': currentIndex,
        'exportedAt': exportedAt.toIso8601String(),
      };

  factory SettingsBackup.fromJson(Map<String, dynamic> json) {
    return SettingsBackup(
      version: json['version'] ?? 1,
      sites: (json['sites'] as List<dynamic>)
          .map((e) => e as Map<String, dynamic>)
          .toList(),
      webspaces: (json['webspaces'] as List<dynamic>)
          .map((e) => e as Map<String, dynamic>)
          .toList(),
      themeMode: json['themeMode'] ?? 0,
      showUrlBar: json['showUrlBar'] ?? false,
      selectedWebspaceId: json['selectedWebspaceId'],
      currentIndex: json['currentIndex'],
      exportedAt: json['exportedAt'] != null
          ? DateTime.parse(json['exportedAt'])
          : DateTime.now(),
    );
  }
}

/// Service for exporting and importing app settings
class SettingsBackupService {
  /// Create a backup from current app state (excluding cookies)
  static SettingsBackup createBackup({
    required List<WebViewModel> webViewModels,
    required List<Webspace> webspaces,
    required int themeMode,
    required bool showUrlBar,
    String? selectedWebspaceId,
    int? currentIndex,
  }) {
    // Convert sites to JSON, excluding cookies
    final sitesJson = webViewModels.map((model) {
      final json = model.toJson();
      // Remove cookies from export
      json['cookies'] = [];
      return json;
    }).toList();

    // Convert webspaces to JSON, excluding the "All" webspace
    final webspacesJson = webspaces
        .where((ws) => ws.id != kAllWebspaceId)
        .map((ws) => ws.toJson())
        .toList();

    return SettingsBackup(
      version: kBackupVersion,
      sites: sitesJson,
      webspaces: webspacesJson,
      themeMode: themeMode,
      showUrlBar: showUrlBar,
      selectedWebspaceId: selectedWebspaceId,
      currentIndex: currentIndex,
      exportedAt: DateTime.now(),
    );
  }

  /// Export settings to a JSON string
  static String exportToJson(SettingsBackup backup) {
    return const JsonEncoder.withIndent('  ').convert(backup.toJson());
  }

  /// Export settings and save to a file
  static Future<bool> exportAndSave(
    BuildContext context, {
    required List<WebViewModel> webViewModels,
    required List<Webspace> webspaces,
    required int themeMode,
    required bool showUrlBar,
    String? selectedWebspaceId,
    int? currentIndex,
  }) async {
    try {
      final backup = createBackup(
        webViewModels: webViewModels,
        webspaces: webspaces,
        themeMode: themeMode,
        showUrlBar: showUrlBar,
        selectedWebspaceId: selectedWebspaceId,
        currentIndex: currentIndex,
      );

      final jsonString = exportToJson(backup);
      final bytes = utf8.encode(jsonString);

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      final defaultFileName = 'webspace_backup_$timestamp.json';

      // Use FilePicker save dialog
      // On mobile (iOS/Android): bytes parameter is required
      // On desktop (macOS/Linux/Windows): bytes not supported, write manually
      final bool isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);

      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Settings Backup',
        fileName: defaultFileName,
        bytes: isMobile ? bytes : null,
      );

      if (outputPath == null) {
        // User cancelled
        return false;
      }

      // On desktop, write file manually since bytes param not supported
      if (!isMobile) {
        final filePath = outputPath.endsWith('.json') ? outputPath : '$outputPath.json';
        final file = File(filePath);
        await file.writeAsString(jsonString);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Settings exported successfully')),
        );
      }
      return true;
    } catch (e, stack) {
      debugPrint('Export failed: $e\n$stack');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
      return false;
    }
  }

  /// Import settings from JSON string
  static SettingsBackup? importFromJson(String jsonString) {
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return SettingsBackup.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  /// Pick a file and import settings
  static Future<SettingsBackup?> pickAndImport(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return null;
      }

      final file = result.files.first;
      String jsonString;

      if (file.bytes != null) {
        // Web or platforms that provide bytes
        jsonString = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        // Platforms that provide file path
        jsonString = await File(file.path!).readAsString();
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not read the selected file')),
          );
        }
        return null;
      }

      final backup = importFromJson(jsonString);
      if (backup == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid backup file format')),
          );
        }
        return null;
      }

      return backup;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
      return null;
    }
  }

  /// Convert backup sites to WebViewModel list
  static List<WebViewModel> restoreSites(
    SettingsBackup backup,
    Function? stateSetterF,
  ) {
    return backup.sites.map((json) {
      // Ensure cookies is an empty list (we don't import cookies)
      json['cookies'] = [];
      return WebViewModel.fromJson(json, stateSetterF);
    }).toList();
  }

  /// Convert backup webspaces to Webspace list
  static List<Webspace> restoreWebspaces(SettingsBackup backup) {
    final webspaces = <Webspace>[Webspace.all()];
    for (final json in backup.webspaces) {
      final ws = Webspace.fromJson(json);
      if (ws.id != kAllWebspaceId) {
        webspaces.add(ws);
      }
    }
    return webspaces;
  }
}
