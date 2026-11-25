import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';

/// A picked file held in memory, as a platform reports one it has read.
final class FakePlatformFile extends PlatformFile {
  FakePlatformFile({required this.name, required this.bytes});

  @override
  final String name;

  final Uint8List bytes;

  @override
  Uri get uri => Uri.file('/picked/$name');

  @override
  XFile get xFile => XFile.fromData(bytes, name: name);

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

/// The platform's open and save dialogs: answers every pick with [file], or
/// as a cancel when it is null, keeps the filter each pick asked for, and
/// writes what a save hands it at [savePath], as every platform does.
final class FakeFilePicker extends FilePickerPlatform {
  FakeFilePicker({this.file});

  /// What the user picks; null cancels.
  PlatformFile? file;

  /// The filter of each pick, in order.
  final List<({FileType type, List<String>? extensions})> asked = [];

  /// Where a save dialog puts the file; null cancels.
  String? savePath;

  /// The file name and MIME type each save dialog offered, in order.
  final List<({String fileName, String mimeType})> offered = [];

  /// Installs a picker for the rest of the test.
  static FakeFilePicker install({PlatformFile? file}) {
    final picker = FakeFilePicker(file: file);
    FilePickerPlatform.instance = picker;
    return picker;
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    asked.add((type: type, extensions: allowedExtensions));
    return file;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    offered.add((fileName: fileName, mimeType: mimeType));
    final path = savePath;
    if (path == null) return null;
    await File(path).writeAsBytes(bytes);
    return Uri.file(path);
  }
}
