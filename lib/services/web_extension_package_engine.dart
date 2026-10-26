/// Reads a browser extension package the user picked (a Chrome or Edge
/// `.crx`, a Firefox `.xpi`, a `.zip`) into its files and what its manifest
/// asks for, or names why it was refused (WEBEXT-013).
///
/// The bytes are untrusted. The container is read here with every offset
/// checked before it is used, every entry checked before any is inflated,
/// and the format told from the bytes, never from the file's name.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/bounded_inflate.dart';

/// What a package may hold. They bound what a crafted archive can make the
/// app allocate; an extension a person picks by hand sits far below them.
abstract final class PackageLimits {
  static const int packageBytes = 128 << 20;
  static const int unpackedBytes = 256 << 20;
  static const int files = 20000;
}

/// How the archive was wrapped.
enum PackageFormat {
  /// A Chrome package, version 2: a public key and a signature, then the
  /// archive.
  crx2,

  /// A Chrome package, version 3: a signed header, then the archive.
  crx3,

  /// A ZIP archive as it is, which a Firefox `.xpi` also is.
  zip,
}

/// What reading a package came to.
sealed class PackageRead {
  const PackageRead();
}

/// A package whose every entry is a safe relative path, inflated to the size
/// and checksum the archive declares, with a manifest the app can summarise.
final class ExtensionPackage extends PackageRead {
  ExtensionPackage({
    required this.format,
    required Map<String, Uint8List> files,
    required this.manifest,
  }) : assert(
         files.keys.every((p) => entryNameProblem(p) == null),
         'every file of a package is a safe relative path',
       ),
       assert(files.containsKey(manifestPath), 'a package has a manifest'),
       files = Map.unmodifiable(files);

  final PackageFormat format;

  /// Each file by its path inside the extension's folder.
  final Map<String, Uint8List> files;
  final ExtensionManifest manifest;

  /// Whether the package carried a signature, which the app does not check:
  /// a Chrome package's header, or a signed Firefox package's `META-INF`.
  bool get signatureUnchecked => switch (format) {
    PackageFormat.crx2 || PackageFormat.crx3 => true,
    PackageFormat.zip => files.keys.any(_mozillaSignature.contains),
  };

  static const _mozillaSignature = {
    'META-INF/mozilla.rsa',
    'META-INF/cose.sig',
  };
}

final class PackageRefused extends PackageRead {
  const PackageRefused(this.why);
  final PackageRefusal why;
}

/// Why a package was refused, each case one message the import screen shows.
sealed class PackageRefusal {
  const PackageRefusal();
}

/// Neither a Chrome package nor a ZIP archive.
final class NotAPackage extends PackageRefusal {
  const NotAPackage();
}

/// The bytes end before a structure they declare.
final class Truncated extends PackageRefusal {
  const Truncated();
}

/// The archive's own records disagree: a directory entry or a file header
/// that is not where the archive says it is.
final class BrokenArchive extends PackageRefusal {
  const BrokenArchive();
}

/// Past [PackageLimits].
final class TooLarge extends PackageRefusal {
  const TooLarge();
}

/// A packaging feature this reader does not take.
final class UnsupportedPackage extends PackageRefusal {
  const UnsupportedPackage(this.feature);
  final PackageFeature feature;
}

enum PackageFeature {
  /// A Chrome package version other than 2 or 3.
  crxVersion,

  /// ZIP64, which no extension needs at these sizes.
  zip64,

  /// An archive split over several files.
  splitArchive,

  /// An encrypted entry.
  encryption,

  /// A compression method other than stored or deflate.
  compressionMethod,
}

/// An entry whose path could land outside the extension's folder, or on top
/// of another entry, once written.
final class UnsafeEntry extends PackageRefusal {
  const UnsafeEntry({required this.name, required this.problem});
  final String name;
  final EntryProblem problem;
}

enum EntryProblem {
  notUtf8,
  absolute,
  backslash,
  controlCharacter,
  dotSegment,
  emptySegment,
  symlink,

  /// The same path as another entry, ignoring case, as a case-insensitive
  /// file system (macOS's default) would write it.
  duplicate,
}

/// An entry whose content is not what the archive declares for it: another
/// size, another checksum, or not a deflate stream.
final class CorruptEntry extends PackageRefusal {
  const CorruptEntry(this.name);
  final String name;
}

/// No `manifest.json` at the archive's root.
final class NoManifest extends PackageRefusal {
  const NoManifest();
}

final class BadManifest extends PackageRefusal {
  const BadManifest(this.problem);
  final ManifestProblem problem;
}

enum ManifestProblem { notJson, notObject, manifestVersion, noName, noVersion }

/// How an extension's background runs.
enum ExtensionBackground {
  none,

  /// A Manifest V3 service worker, started when needed.
  serviceWorker,

  /// A page or scripts started when needed.
  eventPage,

  /// A Manifest V2 page that stays loaded.
  persistentPage,
}

/// What a manifest asks for, as the import screen shows it before anything
/// is added. Names are resolved from the default locale's messages.
final class ExtensionManifest {
  const ExtensionManifest({
    required this.name,
    required this.version,
    required this.manifestVersion,
    required this.description,
    required this.permissions,
    required this.hosts,
    required this.optional,
    required this.background,
    required this.hasAction,
    required this.hasOptionsPage,
  });

  final String name;
  final String version;
  final int manifestVersion;
  final String? description;

  /// The API permissions it needs (`storage`, `tabs`).
  final Set<String> permissions;

  /// The pages it asks to reach: host permissions, content script matches,
  /// and in Manifest V2 the patterns among its permissions.
  final Set<String> hosts;

  /// What it may ask for later, permissions and hosts alike.
  final Set<String> optional;
  final ExtensionBackground background;
  final bool hasAction;
  final bool hasOptionsPage;
}

const String manifestPath = 'manifest.json';

/// [bytes], a package the user picked, read whole or refused.
PackageRead readExtensionPackage(Uint8List bytes) {
  if (bytes.length > PackageLimits.packageBytes) {
    return const PackageRefused(TooLarge());
  }
  return switch (envelopeOf(bytes)) {
    NoArchive(:final why) => PackageRefused(why),
    ArchiveAt(:final format, :final offset) => _readArchive(
      Uint8List.sublistView(bytes, offset),
      format: format,
    ),
  };
}

/// Where the ZIP archive inside a package starts.
sealed class Envelope {
  const Envelope();
}

final class ArchiveAt extends Envelope {
  const ArchiveAt({required this.format, required this.offset});
  final PackageFormat format;
  final int offset;
}

final class NoArchive extends Envelope {
  const NoArchive(this.why);
  final PackageRefusal why;
}

const _crxMagic = [0x43, 0x72, 0x32, 0x34]; // Cr24
const _zipLocalMagic = [0x50, 0x4b, 0x03, 0x04];
const _zipEndMagic = [0x50, 0x4b, 0x05, 0x06];

/// The archive inside [bytes]: a Chrome package's comes after its header,
/// whose lengths are little-endian 32-bit words; a ZIP is its own archive.
Envelope envelopeOf(Uint8List bytes) {
  final b = _Reader(bytes);
  if (b.startsWith(_crxMagic)) {
    switch (b.u32(4)) {
      case null:
        return const NoArchive(Truncated());
      case 2:
        final key = b.u32(8);
        final signature = b.u32(12);
        if (key == null || signature == null) {
          return const NoArchive(Truncated());
        }
        return _archiveAt(
          b,
          format: PackageFormat.crx2,
          offset: 16 + key + signature,
        );
      case 3:
        final header = b.u32(8);
        if (header == null) return const NoArchive(Truncated());
        return _archiveAt(b, format: PackageFormat.crx3, offset: 12 + header);
      default:
        return const NoArchive(UnsupportedPackage(PackageFeature.crxVersion));
    }
  }
  if (b.startsWith(_zipLocalMagic) || b.startsWith(_zipEndMagic)) {
    return const ArchiveAt(format: PackageFormat.zip, offset: 0);
  }
  return const NoArchive(NotAPackage());
}

Envelope _archiveAt(
  _Reader b, {
  required PackageFormat format,
  required int offset,
}) => offset < b.length
    ? ArchiveAt(format: format, offset: offset)
    : const NoArchive(Truncated());

/// Why [name], an entry's path with a directory's trailing `/` removed,
/// could not be written as is inside the extension's folder, or null.
EntryProblem? entryNameProblem(String name) {
  if (name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
    return EntryProblem.absolute;
  }
  if (name.contains(r'\')) return EntryProblem.backslash;
  if (name.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
    return EntryProblem.controlCharacter;
  }
  for (final segment in name.split('/')) {
    if (segment.isEmpty) return EntryProblem.emptySegment;
    if (segment == '.' || segment == '..') return EntryProblem.dotSegment;
  }
  return null;
}

/// One central directory record, checked and not yet read.
typedef _Entry = ({
  String name,
  int method,
  int crc,
  int compressedSize,
  int size,
  int localOffset,
});

const _endSignature = 0x06054b50;
const _directorySignature = 0x02014b50;
const _localSignature = 0x04034b50;
const _endSize = 22;
const _directoryRecordSize = 46;
const _localHeaderSize = 30;
const _zip64Marker16 = 0xffff;
const _zip64Marker32 = 0xffffffff;

PackageRead _readArchive(Uint8List zip, {required PackageFormat format}) {
  final b = _Reader(zip);
  final end = _findEnd(b);
  if (end == null) return const PackageRefused(Truncated());

  final disk = b.u16(end + 4)!;
  final directoryDisk = b.u16(end + 6)!;
  final entriesOnDisk = b.u16(end + 8)!;
  final entryCount = b.u16(end + 10)!;
  final directorySize = b.u32(end + 12)!;
  final directoryOffset = b.u32(end + 16)!;
  if (entryCount == _zip64Marker16 ||
      directorySize == _zip64Marker32 ||
      directoryOffset == _zip64Marker32) {
    return const PackageRefused(UnsupportedPackage(PackageFeature.zip64));
  }
  if (disk != 0 || directoryDisk != 0 || entriesOnDisk != entryCount) {
    return const PackageRefused(
      UnsupportedPackage(PackageFeature.splitArchive),
    );
  }
  if (entryCount > PackageLimits.files) {
    return const PackageRefused(TooLarge());
  }
  final directoryEnd = directoryOffset + directorySize;
  if (directoryEnd > end) return const PackageRefused(BrokenArchive());

  final entries = <_Entry>[];
  final seen = <String>{};
  var unpacked = 0;
  var at = directoryOffset;
  for (var i = 0; i < entryCount; i++) {
    if (at + _directoryRecordSize > directoryEnd ||
        b.u32(at) != _directorySignature) {
      return const PackageRefused(BrokenArchive());
    }
    final madeBy = b.u16(at + 4)!;
    final flags = b.u16(at + 8)!;
    final method = b.u16(at + 10)!;
    final crc = b.u32(at + 16)!;
    final compressedSize = b.u32(at + 20)!;
    final size = b.u32(at + 24)!;
    final nameLength = b.u16(at + 28)!;
    final extraLength = b.u16(at + 30)!;
    final commentLength = b.u16(at + 32)!;
    final external = b.u32(at + 38)!;
    final localOffset = b.u32(at + 42)!;
    final nameStart = at + _directoryRecordSize;
    at = nameStart + nameLength + extraLength + commentLength;
    if (at > directoryEnd) return const PackageRefused(BrokenArchive());

    final nameBytes = Uint8List.sublistView(
      zip,
      nameStart,
      nameStart + nameLength,
    );
    final String raw;
    try {
      raw = utf8.decode(nameBytes);
    } on FormatException {
      return PackageRefused(
        UnsafeEntry(
          name: utf8.decode(nameBytes, allowMalformed: true),
          problem: EntryProblem.notUtf8,
        ),
      );
    }
    final isDirectory = raw.endsWith('/');
    final name = isDirectory ? raw.substring(0, raw.length - 1) : raw;
    if (entryNameProblem(name) case final problem?) {
      return PackageRefused(UnsafeEntry(name: raw, problem: problem));
    }
    const unix = 3;
    const fileTypeMask = 0xf000;
    const symlinkType = 0xa000;
    if (madeBy >> 8 == unix && (external >> 16) & fileTypeMask == symlinkType) {
      return PackageRefused(
        UnsafeEntry(name: raw, problem: EntryProblem.symlink),
      );
    }
    if (!seen.add(name.toLowerCase())) {
      return PackageRefused(
        UnsafeEntry(name: raw, problem: EntryProblem.duplicate),
      );
    }
    if (compressedSize == _zip64Marker32 ||
        size == _zip64Marker32 ||
        localOffset == _zip64Marker32) {
      return const PackageRefused(UnsupportedPackage(PackageFeature.zip64));
    }
    const encrypted = 0x0001;
    const strongEncryption = 0x0040;
    if (flags & (encrypted | strongEncryption) != 0) {
      return const PackageRefused(
        UnsupportedPackage(PackageFeature.encryption),
      );
    }
    if (isDirectory) continue;
    if (method != _stored && method != _deflated) {
      return const PackageRefused(
        UnsupportedPackage(PackageFeature.compressionMethod),
      );
    }
    unpacked += size;
    if (unpacked > PackageLimits.unpackedBytes) {
      return const PackageRefused(TooLarge());
    }
    entries.add((
      name: name,
      method: method,
      crc: crc,
      compressedSize: compressedSize,
      size: size,
      localOffset: localOffset,
    ));
  }

  if (_fileUnderFile(entries) case final name?) {
    return PackageRefused(
      UnsafeEntry(name: name, problem: EntryProblem.duplicate),
    );
  }

  final files = <String, Uint8List>{};
  for (final entry in entries) {
    switch (_contentOf(entry, zip: b, archiveEnd: directoryOffset)) {
      case _No(:final why):
        return PackageRefused(why);
      case _Ok(value: final content):
        files[entry.name] = content;
    }
  }
  return switch (_readManifest(files)) {
    _No(:final why) => PackageRefused(why),
    _Ok(value: final manifest) => ExtensionPackage(
      format: format,
      files: files,
      manifest: manifest,
    ),
  };
}

/// A step of the read that either made its value or refused the package.
sealed class _Step<T> {
  const _Step();
}

final class _Ok<T> extends _Step<T> {
  const _Ok(this.value);
  final T value;
}

final class _No<T> extends _Step<T> {
  const _No(this.why);
  final PackageRefusal why;
}

/// An entry whose path runs through another file, which a file system
/// cannot write: `a` and `a/b.js` both as files.
String? _fileUnderFile(List<_Entry> entries) {
  final names = {for (final e in entries) e.name.toLowerCase()};
  for (final e in entries) {
    final segments = e.name.toLowerCase().split('/');
    for (var i = 1; i < segments.length; i++) {
      if (names.contains(segments.take(i).join('/'))) return e.name;
    }
  }
  return null;
}

/// The end of central directory record: searched back from the end, over
/// at most the longest comment, and taken only where its comment ends the
/// archive.
int? _findEnd(_Reader b) {
  const longestComment = 0xffff;
  final last = b.length - _endSize;
  for (var at = last; at >= 0 && at >= last - longestComment; at--) {
    if (b.u32(at) == _endSignature &&
        at + _endSize + b.u16(at + 20)! == b.length) {
      return at;
    }
  }
  return null;
}

const _stored = 0;
const _deflated = 8;

/// [entry]'s bytes, checked against its declared size and checksum.
_Step<Uint8List> _contentOf(
  _Entry entry, {
  required _Reader zip,
  required int archiveEnd,
}) {
  final header = entry.localOffset;
  if (header + _localHeaderSize > archiveEnd ||
      zip.u32(header) != _localSignature) {
    return const _No(BrokenArchive());
  }
  final start =
      header + _localHeaderSize + zip.u16(header + 26)! + zip.u16(header + 28)!;
  final dataEnd = start + entry.compressedSize;
  if (dataEnd > archiveEnd) return const _No(BrokenArchive());
  final data = Uint8List.sublistView(zip.bytes, start, dataEnd);
  final content = switch (entry.method) {
    _stored => entry.compressedSize == entry.size ? data : null,
    _ => _inflate(data, size: entry.size),
  };
  if (content == null || getCrc32(content) != entry.crc) {
    return _No(CorruptEntry(entry.name));
  }
  return _Ok(content);
}

/// [data] inflated, or null when it is not a deflate stream that makes
/// exactly [size] bytes. The platform's zlib does the inflating, bounded at
/// [size]: a pure Dart inflater loops forever on some hostile streams, and
/// a crafted stream must not make the app allocate past what the archive
/// declared.
Uint8List? _inflate(Uint8List data, {required int size}) {
  final Uint8List? bytes;
  try {
    bytes = inflateBounded(hostDeflateDecoder, compressed: data, limit: size);
  } on FormatException {
    return null;
  }
  return bytes != null && bytes.length == size ? bytes : null;
}

_Step<ExtensionManifest> _readManifest(Map<String, Uint8List> files) {
  final raw = files[manifestPath];
  if (raw == null) return const _No(NoManifest());
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(_withoutBom(raw)));
  } on FormatException {
    return const _No(BadManifest(ManifestProblem.notJson));
  }
  if (decoded is! Map<String, Object?>) {
    return const _No(BadManifest(ManifestProblem.notObject));
  }
  final m = decoded;
  final manifestVersion = switch (m['manifest_version']) {
    final int v when v == 2 || v == 3 => v,
    _ => null,
  };
  if (manifestVersion == null) {
    return const _No(BadManifest(ManifestProblem.manifestVersion));
  }
  final messages = _defaultMessages(m, files: files);
  String? localized(Object? value) => switch (value) {
    final String s when s.trim().isNotEmpty => s.replaceAllMapped(
      _messageRef,
      (r) => messages[r[1]!.toLowerCase()] ?? r[0]!,
    ),
    _ => null,
  };
  final name = localized(m['name']);
  if (name == null) return const _No(BadManifest(ManifestProblem.noName));
  final version = switch (m['version']) {
    final String v when v.trim().isNotEmpty => v,
    _ => null,
  };
  if (version == null) return const _No(BadManifest(ManifestProblem.noVersion));

  final permissions = <String>{};
  final hosts = <String>{};
  for (final p in _strings(m['permissions'])) {
    (manifestVersion == 2 && _isHostPattern(p) ? hosts : permissions).add(p);
  }
  hosts.addAll(_strings(m['host_permissions']));
  if (m['content_scripts'] case final List scripts) {
    for (final script in scripts) {
      if (script case {'matches': final Object? matches}) {
        hosts.addAll(_strings(matches));
      }
    }
  }
  return _Ok(
    ExtensionManifest(
      name: name,
      version: version,
      manifestVersion: manifestVersion,
      description: localized(m['description']),
      permissions: permissions,
      hosts: hosts,
      optional: {
        ..._strings(m['optional_permissions']),
        ..._strings(m['optional_host_permissions']),
      },
      background: _backgroundOf(
        m['background'],
        manifestVersion: manifestVersion,
      ),
      hasAction: [
        'action',
        'browser_action',
        'page_action',
      ].any((key) => m[key] is Map),
      hasOptionsPage:
          m['options_page'] is String ||
          switch (m['options_ui']) {
            {'page': String _} => true,
            _ => false,
          },
    ),
  );
}

final _messageRef = RegExp(r'__MSG_(\w+)__');

/// The default locale's messages by lower-cased name, as Chrome looks them
/// up; empty when the manifest names no default locale or its file is
/// unreadable, which leaves `__MSG_` references as written.
Map<String, String> _defaultMessages(
  Map<String, Object?> manifest, {
  required Map<String, Uint8List> files,
}) {
  final locale = manifest['default_locale'];
  if (locale is! String || entryNameProblem(locale) != null) return const {};
  final raw = files['_locales/$locale/messages.json'];
  if (raw == null) return const {};
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(_withoutBom(raw)));
  } on FormatException {
    return const {};
  }
  if (decoded is! Map<String, Object?>) return const {};
  return {
    for (final MapEntry(:key, :value) in decoded.entries)
      if (value case {'message': final String message})
        key.toLowerCase(): message,
  };
}

ExtensionBackground _backgroundOf(
  Object? background, {
  required int manifestVersion,
}) => switch (background) {
  {'service_worker': String _} => ExtensionBackground.serviceWorker,
  {'persistent': false} => ExtensionBackground.eventPage,
  {'page': String _} || {'scripts': List _} =>
    manifestVersion == 2
        ? ExtensionBackground.persistentPage
        : ExtensionBackground.eventPage,
  _ => ExtensionBackground.none,
};

bool _isHostPattern(String permission) =>
    permission == '<all_urls>' || permission.contains('://');

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

Uint8List _withoutBom(Uint8List bytes) =>
    bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf
    ? Uint8List.sublistView(bytes, 3)
    : bytes;

/// Little-endian reads that answer null past the end instead of throwing.
final class _Reader {
  _Reader(this.bytes) : _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;

  int get length => bytes.length;

  bool _has(int at, {required int count}) =>
      at >= 0 && at + count <= bytes.length;

  int? u16(int at) =>
      _has(at, count: 2) ? _data.getUint16(at, Endian.little) : null;

  int? u32(int at) =>
      _has(at, count: 4) ? _data.getUint32(at, Endian.little) : null;

  bool startsWith(List<int> magic) =>
      _has(0, count: magic.length) &&
      Iterable<int>.generate(magic.length).every((i) => bytes[i] == magic[i]);
}
