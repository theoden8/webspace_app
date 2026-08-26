import 'package:webspace/services/block_stats_detail_storage.dart';

/// In-memory [BlockStatsDetailStore]. Models the contract the encrypted store
/// implements — one payload that survives until it is cleared — so a test can
/// simulate a relaunch without the platform keychain or the disk.
class MemoryBlockStatsDetailStore implements BlockStatsDetailStore {
  String? payload;
  int writes = 0;

  @override
  Future<String?> read() async => payload;

  @override
  Future<void> write(String value) async {
    payload = value;
    writes++;
  }

  @override
  Future<void> clear() async => payload = null;
}
