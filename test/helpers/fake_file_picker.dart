import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// What one pick asked the dialog for.
typedef FilePick = ({FileType type, List<String>? extensions});

/// The platform's open dialog. Each pick is answered with [answer], none
/// when it is null (the user cancelled), and recorded in [asked].
final class FakeFilePicker extends FilePickerPlatform {
  FakeFilePicker({this.answer});

  /// Installs a fake for the running test; its tear-down puts the previous
  /// dialog back.
  factory FakeFilePicker.install({PlatformFile? answer}) {
    final previous = FilePickerPlatform.instance;
    addTearDown(() => FilePickerPlatform.instance = previous);
    return FilePickerPlatform.instance = FakeFilePicker(answer: answer);
  }

  PlatformFile? answer;
  final List<FilePick> asked = [];

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
    return switch (answer) {
      final file? => FilePickerResult([file]),
      null => null,
    };
  }
}
