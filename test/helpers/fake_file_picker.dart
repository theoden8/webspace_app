import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';

/// The platform's open dialog: answers every pick with [file], or as a
/// cancel when it is null, and keeps the filter each pick asked for.
final class FakeFilePicker extends FilePickerPlatform {
  FakeFilePicker({this.file});

  /// What the user picks; null cancels.
  PlatformFile? file;

  /// The filter of each pick, in order.
  final List<({FileType type, List<String>? extensions})> asked = [];

  /// Where a save dialog answers it was put; null cancels.
  String? savePath;

  /// The file name each save dialog offered, in order.
  final List<String?> offered = [];

  /// Installs a picker for the rest of the test.
  static FakeFilePicker install({PlatformFile? file}) {
    final picker = FakeFilePicker(file: file);
    FilePickerPlatform.instance = picker;
    return picker;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    asked.add((type: type, extensions: allowedExtensions));
    return switch (file) {
      final picked? => FilePickerResult([picked]),
      null => null,
    };
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    offered.add(fileName);
    return savePath;
  }
}
