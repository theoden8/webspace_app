import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/utils/concurrency.dart';

/// The images of icons fetched from sites (ICON-008), keyed by the icon's
/// URL, kept on disk so a launch draws them without asking the network again.
/// Only a site whose state may outlive the session writes here, as only such
/// a site keeps its icon's URL.
class IconImageStore {
  IconImageStore({FileStore? store}) : _overrideStore = store;

  static IconImageStore instance = IconImageStore();

  static const String _dir = 'icon_images';

  final FileStore? _overrideStore;
  FileStore? _store;
  final SerialQueue _io = SerialQueue('iconImageIo');

  void initialize() => _store ??=
      _overrideStore ?? defaultFileStore(_dir, kind: StoreKind.cache);

  static String _name(String iconUrl) =>
      sha256.convert(utf8.encode(iconUrl)).toString();

  Future<Uint8List?> read(String iconUrl) async {
    final store = _store;
    if (store == null) return null;
    Uint8List? bytes;
    await _disk(() async => bytes = await store.readBytes(_name(iconUrl)));
    return bytes;
  }

  Future<void> write(String iconUrl, {required Uint8List bytes}) {
    final store = _store;
    if (store == null) return Future.value();
    return _disk(() => store.writeBytes(_name(iconUrl), bytes: bytes));
  }

  Future<void> remove(String iconUrl) {
    final store = _store;
    if (store == null) return Future.value();
    return _disk(() => store.delete(_name(iconUrl)));
  }

  Future<void> clear() {
    final store = _store;
    if (store == null) return Future.value();
    return _disk(() async {
      for (final name in await store.list()) {
        await store.delete(name);
      }
    });
  }

  /// Drop every image whose URL is not in [keptIconUrls]: icons of sites that
  /// were deleted, or whose icon moved to another URL.
  Future<void> removeOrphans(Set<String> keptIconUrls) {
    final store = _store;
    if (store == null) return Future.value();
    final keep = keptIconUrls.map(_name).toSet();
    return _disk(() async {
      for (final name in await store.list()) {
        if (!keep.contains(name)) await store.delete(name);
      }
    });
  }

  /// The images are a cache the sites serve again, so a disk failure costs a
  /// fetch and is logged rather than handed to the caller.
  Future<void> _disk(Future<void> Function() task) => _io.run(() async {
    try {
      await task();
    } on IOException catch (e) {
      LogTag.icon.warning('Icon image store I/O failed: $e');
    }
  });
}
