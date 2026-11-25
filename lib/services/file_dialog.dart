import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'package:webspace/services/file_dialog_web.dart'
    if (dart.library.io) 'package:webspace/services/file_dialog_io.dart'
    as platform;

/// What a [FileDialog] call throws when the platform's dialog fails. A
/// dialog the user cancelled is not a failure.
final class FileDialogFailure implements Exception {
  const FileDialogFailure(this.message);

  /// The platform's report, as its exception printed it, which is also what
  /// a message shown to the user quotes.
  final String message;

  @override
  String toString() => message;
}

/// A file the user picked, read whole.
final class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  /// Its name, with the extension, as the platform reported it.
  final String name;

  final Uint8List bytes;

  /// The extension of [name] without its dot, or null when it has none.
  String? get extension {
    final dot = name.lastIndexOf('.');
    return dot <= 0 || dot == name.length - 1 ? null : name.substring(dot + 1);
  }
}

/// The platform's open and save dialogs. The only caller of file_picker, so
/// what its implementations throw is named once, by `platform.guarded`.
abstract final class FileDialog {
  /// The file the user picked, read, or null when they picked none.
  /// [extensions] limits the choice, null allows any file.
  static Future<PickedFile?> pickFile({List<String>? extensions}) =>
      platform.guarded(() async {
        final file = await FilePicker.pickFile(
          type: extensions == null ? FileType.any : FileType.custom,
          allowedExtensions: extensions,
        );
        if (file == null) return null;
        return PickedFile(name: file.name, bytes: await file.readAsBytes());
      });

  /// Writes [bytes] where the user chose to save [fileName], and names that
  /// place: a path, or the URI where the platform names no path (Android's
  /// documents). Null when the user chose none.
  static Future<String?> saveFile({
    required String dialogTitle,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) =>
      platform.guarded(() async {
        final saved = await FilePicker.saveFile(
          dialogTitle: dialogTitle,
          fileName: fileName,
          bytes: bytes,
          mimeType: mimeType,
        );
        if (saved == null) return null;
        return saved.isScheme('file') ? saved.toFilePath() : '$saved';
      });
}
