import 'dart:async';
import 'dart:typed_data';

import 'package:webspace/services/file_store.dart';

/// Which call of a [HeldFileStore] waits.
enum HeldCall { readText, writeText }

/// A [FileStore] over another whose first [HeldCall] waits for [release],
/// so a test can land an event while that call is in flight. [reached]
/// completes when it starts waiting.
class HeldFileStore implements FileStore {
  HeldFileStore(this._inner, {required this.holds});

  final FileStore _inner;
  final HeldCall holds;
  final Completer<void> reached = Completer<void>();
  final Completer<void> release = Completer<void>();

  Future<void> _wait(HeldCall call) async {
    if (call != holds || reached.isCompleted) return;
    reached.complete();
    await release.future;
  }

  @override
  Future<String?> readText(String name) async {
    await _wait(HeldCall.readText);
    return _inner.readText(name);
  }

  @override
  Future<void> writeText(String name, {required String contents}) async {
    await _wait(HeldCall.writeText);
    await _inner.writeText(name, contents: contents);
  }

  @override
  Future<void> ensure() => _inner.ensure();
  @override
  Future<bool> exists(String name) => _inner.exists(name);
  @override
  Future<Uint8List?> readBytes(String name) => _inner.readBytes(name);
  @override
  Future<void> writeBytes(String name, {required List<int> bytes}) =>
      _inner.writeBytes(name, bytes: bytes);
  @override
  Future<void> delete(String name) => _inner.delete(name);
  @override
  Future<String?> stamp(String name) => _inner.stamp(name);
  @override
  Future<List<String>> list() => _inner.list();
  @override
  Future<void> deleteAll() => _inner.deleteAll();
}
