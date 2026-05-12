import 'dart:convert' show base64Url;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const int kArchiveSlotCount = 16;
const int kArchiveSlotSize = 128 * 1024;
const int kArchiveSlotNonceLength = 12;
const int kArchiveSlotMacLength = 16;
const int kArchiveSlotPlaintextSize =
    kArchiveSlotSize - kArchiveSlotNonceLength - kArchiveSlotMacLength;
const int kArchiveSlotPayloadHeader = 4;
const int kArchiveSlotMaxPayload =
    kArchiveSlotPlaintextSize - kArchiveSlotPayloadHeader;

String _slotKeyName(int index) {
  final s = index.toString().padLeft(2, '0');
  return 'archive_slot_$s';
}

class ArchiveStorage {
  ArchiveStorage({FlutterSecureStorage? secureStorage})
      : _storage = secureStorage ??
            const FlutterSecureStorage(
              aOptions:
                  AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;
  final Random _random = Random.secure();
  bool _initialized = false;

  Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }
    for (var i = 0; i < kArchiveSlotCount; i++) {
      final key = _slotKeyName(i);
      final existing = await _storage.read(key: key);
      if (existing == null) {
        await _storage.write(key: key, value: _randomBase64(kArchiveSlotSize));
      }
    }
    _initialized = true;
  }

  Future<Uint8List> readSlot(int index) async {
    _checkIndex(index);
    final raw = await _storage.read(key: _slotKeyName(index));
    if (raw == null) {
      return _randomBytes(kArchiveSlotSize);
    }
    return _decodeBase64(raw);
  }

  Future<List<Uint8List>> readAllSlots() async {
    final result = <Uint8List>[];
    for (var i = 0; i < kArchiveSlotCount; i++) {
      result.add(await readSlot(i));
    }
    return result;
  }

  Future<void> writeSlot(int index, Uint8List bytes) async {
    _checkIndex(index);
    if (bytes.length != kArchiveSlotSize) {
      throw ArgumentError(
        'slot bytes must be exactly $kArchiveSlotSize B '
        '(got ${bytes.length} B)',
      );
    }
    await _storage.write(key: _slotKeyName(index), value: _encodeBase64(bytes));
  }

  static Uint8List aadForSlot(int index) {
    final bd = ByteData(4);
    bd.setUint32(0, index, Endian.big);
    return bd.buffer.asUint8List();
  }

  int pickRandomUnclaimedSlot(Set<int> claimed) {
    final available = <int>[];
    for (var i = 0; i < kArchiveSlotCount; i++) {
      if (!claimed.contains(i)) {
        available.add(i);
      }
    }
    if (available.isEmpty) {
      throw StateError('all $kArchiveSlotCount archive slots are claimed');
    }
    return available[_random.nextInt(available.length)];
  }

  void _checkIndex(int index) {
    if (index < 0 || index >= kArchiveSlotCount) {
      throw RangeError.range(index, 0, kArchiveSlotCount - 1, 'index');
    }
  }

  Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    _fillRandom(out, 0);
    return out;
  }

  void _fillRandom(Uint8List buffer, int from) {
    for (var i = from; i < buffer.length; i++) {
      buffer[i] = _random.nextInt(256);
    }
  }

  String _randomBase64(int length) {
    return _encodeBase64(_randomBytes(length));
  }

  String _encodeBase64(Uint8List bytes) {
    return base64Url.encode(bytes);
  }

  Uint8List _decodeBase64(String s) {
    return Uint8List.fromList(base64Url.decode(s));
  }
}

