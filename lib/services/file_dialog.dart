import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'package:webspace/services/file_dialog_web.dart'
    if (dart.library.io) 'package:webspace/services/file_dialog_io.dart'
    as platform;

export 'package:file_picker/file_picker.dart' show PlatformFile;

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

/// The platform's open and save dialogs. The only caller of file_picker, so
/// what its implementations throw is named once, by `platform.guarded`.
abstract final class FileDialog {
  /// The file the user picked, or null when they picked none. [extensions]
  /// limits the choice, null allows any file; [withData] reads its bytes
  /// where the platform would otherwise hand over only a path.
  static Future<PlatformFile?> pickFile({
    List<String>? extensions,
    bool withData = false,
  }) async {
    final result = await platform.guarded(() => FilePicker.pickFiles(
          type: extensions == null ? FileType.any : FileType.custom,
          allowedExtensions: extensions,
          withData: withData,
        ));
    return result?.files.firstOrNull;
  }

  /// The path the user chose to save [fileName] at, or null when they chose
  /// none. The dialog writes [bytes] there itself when given (Android and
  /// iOS require them); without them the caller writes to the path.
  static Future<String?> saveFile({
    required String dialogTitle,
    required String fileName,
    Uint8List? bytes,
  }) =>
      platform.guarded(() => FilePicker.saveFile(
            dialogTitle: dialogTitle,
            fileName: fileName,
            bytes: bytes,
          ));
}
