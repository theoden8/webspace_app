import 'dart:convert';
import 'dart:typed_data';

import 'archive_crypto.dart';
import 'archive_key_derivation.dart';
import 'archive_storage.dart';

const int kArchiveStateVersion = 1;

class ArchiveState {
  ArchiveState({
    this.version = kArchiveStateVersion,
    DateTime? createdAt,
    List<Map<String, dynamic>>? webspaces,
    List<Map<String, dynamic>>? sites,
    Map<String, List<Map<String, dynamic>>>? cookies,
    this.selectedWebspaceId,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        webspaces = webspaces ?? <Map<String, dynamic>>[],
        sites = sites ?? <Map<String, dynamic>>[],
        cookies = cookies ?? <String, List<Map<String, dynamic>>>{};

  final int version;
  final DateTime createdAt;
  final List<Map<String, dynamic>> webspaces;
  final List<Map<String, dynamic>> sites;
  final Map<String, List<Map<String, dynamic>>> cookies;
  String? selectedWebspaceId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'createdAt': createdAt.toIso8601String(),
        'webspaces': webspaces,
        'sites': sites,
        'cookies': cookies,
        if (selectedWebspaceId != null)
          'selectedWebspaceId': selectedWebspaceId,
      };

  factory ArchiveState.fromJson(Map<String, dynamic> json) {
    final rawCookies = json['cookies'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    final cookies = <String, List<Map<String, dynamic>>>{};
    rawCookies.forEach((siteId, value) {
      if (value is List) {
        cookies[siteId] = value
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }
    });
    return ArchiveState(
      version: json['version'] as int? ?? kArchiveStateVersion,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
              DateTime.now().toUtc(),
      webspaces: ((json['webspaces'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(),
      sites: ((json['sites'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(),
      cookies: cookies,
      selectedWebspaceId: json['selectedWebspaceId'] as String?,
    );
  }
}

class ArchiveHandle {
  ArchiveHandle._({
    required Uint8List key,
    required this.slotIndex,
    required this.state,
  }) : _key = key;

  Uint8List _key;
  bool _closed = false;
  final int slotIndex;
  final ArchiveState state;

  Uint8List get key {
    if (_closed) {
      throw StateError('archive handle has been closed');
    }
    return _key;
  }

  bool get isClosed => _closed;

  void _zeroizeAndMarkClosed() {
    if (_closed) return;
    ArchiveCrypto.zeroize(_key);
    _key = Uint8List(0);
    _closed = true;
  }
}

/// Turns a passphrase into an archive key. [salt] is the per-install salt, or
/// null for the superseded passphrase-derived one.
typedef ArchiveKeyDeriver = Future<Uint8List> Function(
  String passphrase,
  Uint8List? salt,
);

Future<Uint8List> _argon2Derive(String passphrase, Uint8List? salt) {
  return salt == null
      ? ArchiveKeyDerivation.deriveLegacy(passphrase)
      : ArchiveKeyDerivation.derive(passphrase, salt);
}

class Archive {
  /// [deriveKey] exists so tests can exercise the passphrase paths without
  /// paying ~1s of Argon2id per call; production always takes the default.
  Archive({ArchiveStorage? storage, ArchiveKeyDeriver? deriveKey})
      : _storage = storage ?? ArchiveStorage(),
        _derive = deriveKey ?? _argon2Derive;

  final ArchiveStorage _storage;
  final ArchiveKeyDeriver _derive;
  final List<ArchiveHandle> _openHandles = <ArchiveHandle>[];

  List<ArchiveHandle> get openArchives =>
      List<ArchiveHandle>.unmodifiable(_openHandles);

  Future<void> ensureInitialized() => _storage.ensureInitialized();

  Future<ArchiveHandle?> tryOpen(String passphrase) async {
    await ensureInitialized();
    final saltEntry = await _storage.ensureKdfSalt();
    final key = await _derive(passphrase, saltEntry.salt);
    final match = await _scanSlots(key);
    if (match != null) {
      return _adopt(key, match);
    }
    if (!saltEntry.legacyPossible) {
      ArchiveCrypto.zeroize(key);
      return null;
    }
    final legacyKey = await _derive(passphrase, null);
    final legacyMatch = await _scanSlots(legacyKey);
    ArchiveCrypto.zeroize(legacyKey);
    if (legacyMatch == null) {
      ArchiveCrypto.zeroize(key);
      return null;
    }
    final handle = _adopt(key, legacyMatch);
    if (identical(handle.key, key)) {
      // Re-seal under the per-install salt so this slot never needs the legacy
      // derivation again.
      await _persist(handle);
    }
    return handle;
  }

  Future<ArchiveHandle?> tryOpenWithKey(Uint8List key) async {
    await ensureInitialized();
    final match = await _scanSlots(key);
    if (match == null) {
      ArchiveCrypto.zeroize(key);
      return null;
    }
    return _adopt(key, match);
  }

  ArchiveHandle _adopt(Uint8List key, _SlotMatch match) {
    final existing = _findOpenBySlot(match.slotIndex);
    if (existing != null) {
      ArchiveCrypto.zeroize(key);
      return existing;
    }
    final handle = ArchiveHandle._(
      key: key,
      slotIndex: match.slotIndex,
      state: ArchiveState.fromJson(
        jsonDecode(utf8.decode(match.plaintext)) as Map<String, dynamic>,
      ),
    );
    _openHandles.add(handle);
    return handle;
  }

  Future<ArchiveHandle> create(String passphrase) async {
    await ensureInitialized();
    final saltEntry = await _storage.ensureKdfSalt();
    if (saltEntry.legacyPossible) {
      // A slot still sealed under the legacy key would be invisible to
      // [createWithKey]'s scan, and claiming a second slot for the same
      // passphrase would strand it.
      final legacyKey = await _derive(passphrase, null);
      final legacyMatch = await _scanSlots(legacyKey);
      ArchiveCrypto.zeroize(legacyKey);
      if (legacyMatch != null) {
        throw StateError(
          'an archive already exists for this passphrase '
          '(slot ${legacyMatch.slotIndex})',
        );
      }
    }
    final key = await _derive(passphrase, saltEntry.salt);
    return createWithKey(key);
  }

  Future<ArchiveHandle> createWithKey(Uint8List key) async {
    await ensureInitialized();
    final claimed = <int>{for (final h in _openHandles) h.slotIndex};
    final scan = await _scanSlots(key);
    if (scan != null) {
      ArchiveCrypto.zeroize(key);
      throw StateError(
        'an archive already exists for this passphrase (slot ${scan.slotIndex})',
      );
    }
    final slotIndex = _storage.pickRandomUnclaimedSlot(claimed);
    final handle = ArchiveHandle._(
      key: key,
      slotIndex: slotIndex,
      state: ArchiveState(),
    );
    await _persist(handle);
    _openHandles.add(handle);
    return handle;
  }

  Future<void> save(ArchiveHandle handle) async {
    if (handle.isClosed) {
      throw StateError('cannot save a closed archive handle');
    }
    if (!_openHandles.contains(handle)) {
      throw StateError('archive handle is not registered with this orchestrator');
    }
    await _persist(handle);
  }

  Future<void> close(ArchiveHandle handle) async {
    if (handle.isClosed) return;
    if (_openHandles.contains(handle)) {
      await _persist(handle);
      _openHandles.remove(handle);
    }
    handle._zeroizeAndMarkClosed();
  }

  Future<void> closeAll() async {
    while (_openHandles.isNotEmpty) {
      await close(_openHandles.first);
    }
  }

  /// Restores self-contained sections produced by [exportSection] into
  /// the slot pool. Tries [passphrase] against each base64 blob; a blob
  /// that decrypts is written to its archive's slot (existing slot for
  /// that key, or a fresh one). Restored archives are written to disk
  /// but NOT opened. Returns the blobs that did not decrypt under this
  /// passphrase, so the caller can prompt again for a different one.
  Future<List<String>> importSections(
    String passphrase,
    List<String> base64Sections,
  ) async {
    await ensureInitialized();
    final localSalt = (await _storage.ensureKdfSalt()).salt;
    final derived = <String, Uint8List>{};
    Future<Uint8List> keyFor(Uint8List? salt) async {
      final cacheKey = salt == null ? 'legacy' : base64.encode(salt);
      final hit = derived[cacheKey];
      if (hit != null) return hit;
      final key = await _derive(passphrase, salt);
      derived[cacheKey] = key;
      return key;
    }

    final unmatched = <String>[];
    try {
      for (final b64 in base64Sections) {
        final section = _ArchiveSection.parse(b64);
        if (section == null) {
          unmatched.add(b64);
          continue;
        }
        final plaintext =
            await ArchiveCrypto.open(await keyFor(section.salt), section.wire);
        if (plaintext == null) {
          unmatched.add(b64);
          continue;
        }
        final stateJson =
            jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
        // Re-key onto this device's salt: the section was sealed under the
        // exporting device's, which this device's open path never derives.
        await _writeState(
          await keyFor(localSalt),
          ArchiveState.fromJson(stateJson),
        );
      }
    } finally {
      for (final key in derived.values) {
        ArchiveCrypto.zeroize(key);
      }
    }
    return unmatched;
  }

  /// Key-based core of [importSections]. Does not consume or zeroize
  /// [key] (the caller owns its lifetime). Exposed for tests so they
  /// can exercise section round-tripping without the per-call Argon2id
  /// cost; derivation itself is covered by the crypto tests.
  Future<List<String>> importSectionsWithKey(
    Uint8List key,
    List<String> base64Sections,
  ) async {
    await ensureInitialized();
    final unmatched = <String>[];
    for (final b64 in base64Sections) {
      final section = _ArchiveSection.parse(b64);
      if (section == null) {
        unmatched.add(b64);
        continue;
      }
      final plaintext = await ArchiveCrypto.open(key, section.wire);
      if (plaintext == null) {
        unmatched.add(b64);
        continue;
      }
      final stateJson =
          jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      await _writeState(key, ArchiveState.fromJson(stateJson));
    }
    return unmatched;
  }

  /// Seals an archive's state into a self-contained base64 blob (no
  /// slot AAD) that [importSections] can later restore under the same
  /// passphrase.
  ///
  /// The blob carries this install's Argon2id salt in the clear ahead of the
  /// ciphertext: the receiving device derives with its own salt, so without it
  /// a backup could only ever be restored onto the device that made it
  /// (ARCH-002, "same passphrase across devices"). The salt is public input to
  /// a KDF, not a secret — what it costs an attacker is the ability to reuse
  /// one precomputed table against every other install.
  Future<String> exportSection(ArchiveHandle handle) async {
    final salt = (await _storage.ensureKdfSalt()).salt;
    final plaintext =
        Uint8List.fromList(utf8.encode(jsonEncode(handle.state.toJson())));
    final wire = await ArchiveCrypto.seal(handle.key, plaintext);
    return _ArchiveSection(salt: salt, wire: wire).encode();
  }

  Future<void> _writeState(Uint8List key, ArchiveState state) async {
    final match = await _scanSlots(key);
    final int slotIndex;
    if (match != null) {
      slotIndex = match.slotIndex;
    } else {
      final claimed = <int>{for (final h in _openHandles) h.slotIndex};
      slotIndex = _storage.pickRandomUnclaimedSlot(claimed);
    }
    // Build a transient handle over a private copy of the key just to
    // persist; never registered as open, zeroed immediately after.
    final handle = ArchiveHandle._(
      key: Uint8List.fromList(key),
      slotIndex: slotIndex,
      state: state,
    );
    await _persist(handle);
    handle._zeroizeAndMarkClosed();
  }

  Future<_SlotMatch?> _scanSlots(Uint8List key) async {
    final slots = await _storage.readAllSlots();
    for (var i = 0; i < slots.length; i++) {
      final padded = await ArchiveCrypto.open(
        key,
        slots[i],
        aad: ArchiveStorage.aadForSlot(i),
      );
      if (padded == null) continue;
      if (padded.length != kArchiveSlotPlaintextSize) continue;
      final payloadLength = ByteData.view(padded.buffer, padded.offsetInBytes)
          .getUint32(0, Endian.big);
      if (payloadLength > kArchiveSlotMaxPayload) continue;
      final payload = Uint8List.sublistView(
        padded,
        kArchiveSlotPayloadHeader,
        kArchiveSlotPayloadHeader + payloadLength,
      );
      return _SlotMatch(slotIndex: i, plaintext: Uint8List.fromList(payload));
    }
    return null;
  }

  ArchiveHandle? _findOpenBySlot(int slotIndex) {
    for (final h in _openHandles) {
      if (h.slotIndex == slotIndex) return h;
    }
    return null;
  }

  Future<void> _persist(ArchiveHandle handle) async {
    final payload =
        Uint8List.fromList(utf8.encode(jsonEncode(handle.state.toJson())));
    if (payload.length > kArchiveSlotMaxPayload) {
      throw StateError(
        'archive payload (${payload.length} B) exceeds slot capacity '
        '($kArchiveSlotMaxPayload B)',
      );
    }
    final padded = Uint8List(kArchiveSlotPlaintextSize);
    ByteData.view(padded.buffer)
        .setUint32(0, payload.length, Endian.big);
    padded.setRange(
      kArchiveSlotPayloadHeader,
      kArchiveSlotPayloadHeader + payload.length,
      payload,
    );
    fillSecureRandom(padded, kArchiveSlotPayloadHeader + payload.length);
    final wire = await ArchiveCrypto.seal(
      handle.key,
      padded,
      aad: ArchiveStorage.aadForSlot(handle.slotIndex),
    );
    await _storage.writeSlot(handle.slotIndex, wire);
  }
}

class _SlotMatch {
  _SlotMatch({required this.slotIndex, required this.plaintext});
  final int slotIndex;
  final Uint8List plaintext;
}

/// Wire framing for an exported section: `"WSA1" || salt || AEAD wire`. A blob
/// with no magic predates the per-install salt, so its key came from the
/// passphrase alone ([ArchiveKeyDerivation.deriveLegacy]).
class _ArchiveSection {
  _ArchiveSection({required this.salt, required this.wire});

  static const List<int> _magic = <int>[0x57, 0x53, 0x41, 0x31];

  final Uint8List? salt;
  final Uint8List wire;

  static _ArchiveSection? parse(String base64Section) {
    Uint8List raw;
    try {
      raw = Uint8List.fromList(base64.decode(base64Section));
    } catch (_) {
      return null;
    }
    final headerLength = _magic.length + kArchiveSaltLength;
    if (raw.length > headerLength && _hasMagic(raw)) {
      return _ArchiveSection(
        salt: Uint8List.sublistView(raw, _magic.length, headerLength),
        wire: Uint8List.sublistView(raw, headerLength),
      );
    }
    return _ArchiveSection(salt: null, wire: raw);
  }

  static bool _hasMagic(Uint8List raw) {
    for (var i = 0; i < _magic.length; i++) {
      if (raw[i] != _magic[i]) return false;
    }
    return true;
  }

  String encode() {
    final s = salt;
    if (s == null) {
      return base64.encode(wire);
    }
    final out = Uint8List(_magic.length + s.length + wire.length);
    out.setRange(0, _magic.length, _magic);
    out.setRange(_magic.length, _magic.length + s.length, s);
    out.setRange(_magic.length + s.length, out.length, wire);
    return base64.encode(out);
  }
}
