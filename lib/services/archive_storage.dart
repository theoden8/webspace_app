import 'dart:convert' show base64Url;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'archive_crypto.dart' show kArchiveSaltLength;

const int kArchiveSlotCount = 16;
const int kArchiveSlotSize = 128 * 1024;
const int kArchiveSlotNonceLength = 12;
const int kArchiveSlotMacLength = 16;
const int kArchiveSlotPlaintextSize =
    kArchiveSlotSize - kArchiveSlotNonceLength - kArchiveSlotMacLength;
const int kArchiveSlotPayloadHeader = 4;
const int kArchiveSlotMaxPayload =
    kArchiveSlotPlaintextSize - kArchiveSlotPayloadHeader;

/// Secure-storage entry holding the per-install Argon2id salt (ARCH-002).
const String kArchiveKdfSaltKey = 'archive_kdf_salt';

/// One flag byte followed by the salt. Fixed length in both flag states, so
/// the entry looks the same on every install.
const int kArchiveKdfSaltEntryLength = 1 + kArchiveSaltLength;

String _slotKeyName(int index) {
  final s = index.toString().padLeft(2, '0');
  return 'archive_slot_$s';
}

/// The per-install Argon2id salt plus the one bit of provenance the open path
/// needs.
class ArchiveKdfSalt {
  const ArchiveKdfSalt({required this.salt, required this.legacyPossible});

  final Uint8List salt;

  /// True when the slot pool already existed when the salt was minted, so a
  /// slot may still be sealed under the pre-salt, passphrase-derived key.
  /// Records install age only — never archive presence or count, which would
  /// break ARCH-001.
  final bool legacyPossible;
}

final Random _fillRng = Random.secure();

/// Draws 32 bits per `Random.secure()` call instead of 8: each call is a
/// native entropy fetch (~2us), and per-byte draws made first-run slot-pool
/// init plus every slot persist cost whole seconds of startup/CI time.
void fillSecureRandom(Uint8List buffer, [int from = 0]) {
  var i = from;
  for (; i + 4 <= buffer.length; i += 4) {
    final v = _fillRng.nextInt(0x100000000);
    buffer[i] = v;
    buffer[i + 1] = v >> 8;
    buffer[i + 2] = v >> 16;
    buffer[i + 3] = v >> 24;
  }
  for (; i < buffer.length; i++) {
    buffer[i] = _fillRng.nextInt(256);
  }
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
  ArchiveKdfSalt? _kdfSalt;

  Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }
    var poolExisted = false;
    for (var i = 0; i < kArchiveSlotCount; i++) {
      final key = _slotKeyName(i);
      final existing = await _storage.read(key: key);
      if (existing == null) {
        await _storage.write(key: key, value: _randomBase64(kArchiveSlotSize));
      } else {
        poolExisted = true;
      }
    }
    await ensureKdfSalt(poolPredatesSalt: poolExisted);
    _initialized = true;
  }

  /// Reads the per-install Argon2id salt, minting it if absent.
  ///
  /// Written whenever the slot pool is, whether or not an archive exists: an
  /// entry that only appeared once the user had an archive would make the
  /// archive count observable and break ARCH-001.
  Future<ArchiveKdfSalt> ensureKdfSalt({bool poolPredatesSalt = false}) async {
    final cached = _kdfSalt;
    if (cached != null) {
      return cached;
    }
    final raw = await _storage.read(key: kArchiveKdfSaltKey);
    if (raw != null) {
      try {
        final bytes = _decodeBase64(raw);
        if (bytes.length == kArchiveKdfSaltEntryLength) {
          final parsed = ArchiveKdfSalt(
            salt: Uint8List.sublistView(bytes, 1),
            legacyPossible: bytes[0] != 0,
          );
          _kdfSalt = parsed;
          return parsed;
        }
      } catch (_) {
        // Unreadable entry: fall through and mint a fresh one. Archives sealed
        // under the lost salt are unrecoverable, exactly as they would be if
        // the keychain itself had dropped the slots.
      }
    }
    final salt = _randomBytes(kArchiveSaltLength);
    final entry = Uint8List(kArchiveKdfSaltEntryLength);
    entry[0] = poolPredatesSalt ? 1 : 0;
    entry.setRange(1, kArchiveKdfSaltEntryLength, salt);
    await _storage.write(key: kArchiveKdfSaltKey, value: _encodeBase64(entry));
    final minted =
        ArchiveKdfSalt(salt: salt, legacyPossible: poolPredatesSalt);
    _kdfSalt = minted;
    return minted;
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
    fillSecureRandom(out);
    return out;
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

