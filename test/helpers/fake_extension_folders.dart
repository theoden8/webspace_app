import 'dart:io' show FileSystemException;
import 'dart:typed_data';

import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/settings/web_extension.dart';

/// [ExtensionFolders] in memory: each folder its files by path, as a disk
/// would hold them. [failAfter] makes an unpack fail once it has written that
/// many files, as a full disk would.
class FakeExtensionFolders implements ExtensionFolders {
  final Map<String, Map<String, Uint8List>> folders = {};
  int? failAfter;

  @override
  String folderOf(WebExtensionId id) => '/docs/web_extensions/$id';

  @override
  Future<void> unpack(
    WebExtensionId id, {
    required Map<String, Uint8List> files,
  }) async {
    final folder = folders.putIfAbsent(id, () => {});
    for (final MapEntry(key: path, value: bytes) in files.entries) {
      if (failAfter case final limit? when folder.length >= limit) {
        throw const FileSystemException('No space left on device');
      }
      folder[path] = bytes;
    }
  }

  @override
  Future<void> delete(WebExtensionId id) async => folders.remove(id);

  /// Whole or not at all, as the host's staged replace is: [failAfter]
  /// fails it before anything is put in place.
  @override
  Future<void> replace(
    WebExtensionId id, {
    required Map<String, Uint8List> files,
  }) async {
    if (failAfter case final limit? when files.length > limit) {
      throw const FileSystemException('No space left on device');
    }
    folders[id] = Map.of(files);
  }

  @override
  Future<Map<String, Uint8List>> read(WebExtensionId id) async =>
      Map.of(folders[id] ?? const {});

  @override
  Future<List<String>> names() async => folders.keys.toList();
}
