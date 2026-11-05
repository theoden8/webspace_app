import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/capture.dart';

/// The platform's dialog, answering every pick with [file].
final class _Picked extends FilePickerPlatform {
  _Picked(this.file);

  final PlatformFile file;

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
  }) async =>
      FilePickerResult([file]);
}

/// The chunk types of a PNG, in order.
List<String> _chunks(Uint8List png) {
  final data = ByteData.sublistView(png);
  final types = <String>[];
  for (var at = 8; at + 8 <= png.length;) {
    final length = data.getUint32(at);
    types.add(String.fromCharCodes(png.sublist(at + 4, at + 8)));
    at += 12 + length;
  }
  return types;
}

const _device = 'Pixel 9 Pro';

void main() {
  test(
      'SHARE-016: a picked screenshot naming its device reaches the model as '
      'a PNG with no text, EXIF or ICC chunk', () async {
    final shot = img.Image(width: 4, height: 4)
      ..textData = {'XML:com.adobe.xmp': '<x:xmpmeta>$_device</x:xmpmeta>'}
      ..exif.imageIfd['Model'] = _device;
    final raw = Uint8List.fromList(img.encodePng(shot));
    expect(_chunks(raw), contains('tEXt'), reason: 'the planted XMP block');
    expect(String.fromCharCodes(raw), contains(_device));
    FilePickerPlatform.instance = _Picked(
      PlatformFile(name: 'Screenshot.png', size: raw.length, bytes: raw),
    );

    final picked = await VirtualMediaPicker.pick(CaptureMedium.visual);

    final source = picked.source!;
    final url = source.dataUrl;
    expect(url, startsWith('data:image/png;base64,'));
    final bytes = base64Decode(url.substring(url.indexOf(',') + 1));
    expect(String.fromCharCodes(bytes), isNot(contains(_device)));
    expect(_chunks(bytes),
        isNot(anyOf(contains('tEXt'), contains('iTXt'), contains('zTXt'),
            contains('eXIf'), contains('iCCP'))));
    expect(img.decodePng(bytes)!.width, 4);
  });
}
