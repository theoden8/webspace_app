import 'dart:async';

import 'package:webspace/services/block_stats_detail_storage.dart';

/// In-memory [BlockStatsDetailStore]. Models the contract the encrypted store
/// implements — one payload that survives until it is cleared — so a test can
/// simulate a relaunch without the platform keychain or the disk.
class MemoryBlockStatsDetailStore implements BlockStatsDetailStore {
  String? payload;
  int writes = 0;

  /// Models a store that cannot write (no keychain, read-only disk): the
  /// service must keep the payload pending instead of dropping it.
  bool writable = true;

  /// Gate a write mid-flight, so a test can record while one is in progress.
  Completer<void>? writeGate;

  @override
  Future<String?> read() async => payload;

  @override
  Future<bool> write(String value) async {
    await writeGate?.future;
    if (!writable) return false;
    payload = value;
    writes++;
    return true;
  }

  @override
  Future<void> clear() async => payload = null;
}
