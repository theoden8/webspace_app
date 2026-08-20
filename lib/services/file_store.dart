// A named directory of text files, behind an interface.
//
// The services that keep on-disk caches (HTML cache, LocalCDN, imported HTML,
// blocklists) all do the same handful of things: read, write, delete, list and
// wipe files under one directory. Naming that as a seam does two things at
// once — the pure logic above it (encryption, eviction, parsing) becomes
// testable with an in-memory fake, and the dart:io implementation stops being
// baked into files that screens import, which is what kept those screens off
// the web target.
//
// Native builds get [IoFileStore]. The design gallery gets [MemoryFileStore],
// so a cache-backed screen renders in its empty state instead of failing to
// compile. Tests can pass either.

import 'dart:convert';
import 'dart:typed_data';

import 'file_store_web.dart' if (dart.library.io) 'file_store_io.dart' as impl;

abstract class FileStore {
  /// Create the directory if it does not exist.
  Future<void> ensure();

  Future<bool> exists(String name);

  /// File contents, or null when the file is absent or unreadable.
  Future<String?> readText(String name);

  Future<void> writeText(String name, String contents);

  /// Binary contents, or null when absent or unreadable.
  Future<Uint8List?> readBytes(String name);

  Future<void> writeBytes(String name, List<int> bytes);

  Future<void> delete(String name);

  /// File names (not paths) currently in the directory.
  Future<List<String>> list();

  /// Remove the directory and everything in it.
  Future<void> deleteAll();
}

/// The platform's store for a directory under the app's documents directory.
FileStore defaultFileStore(String directoryName) =>
    impl.createFileStore(directoryName);

/// In-memory [FileStore]. The web implementation and the fake tests reach for:
/// same semantics, no disk.
class MemoryFileStore implements FileStore {
  final Map<String, String> _files = {};
  final Map<String, Uint8List> _bytes = {};

  @override
  Future<void> ensure() async {}

  @override
  Future<bool> exists(String name) async =>
      _files.containsKey(name) || _bytes.containsKey(name);

  @override
  Future<String?> readText(String name) async => _files[name];

  @override
  Future<void> writeText(String name, String contents) async {
    _files[name] = contents;
  }

  @override
  Future<Uint8List?> readBytes(String name) async {
    final bytes = _bytes[name];
    if (bytes != null) return bytes;
    final text = _files[name];
    return text == null ? null : Uint8List.fromList(utf8.encode(text));
  }

  @override
  Future<void> writeBytes(String name, List<int> bytes) async {
    _bytes[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String name) async {
    _files.remove(name);
    _bytes.remove(name);
  }

  @override
  Future<List<String>> list() async => {..._files.keys, ..._bytes.keys}.toList();

  @override
  Future<void> deleteAll() async {
    _files.clear();
    _bytes.clear();
  }
}
