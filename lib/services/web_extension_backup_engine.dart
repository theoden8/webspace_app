/// How a settings backup carries the extension library, and how an import
/// links what it carries to this device's (WEBEXT-011).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_backup.dart';

/// The SHA-256 of an extension's [files] in path order, each as its path,
/// its length and its bytes: the same wherever the same files are unpacked.
String extensionFingerprint(Map<String, Uint8List> files) {
  final paths = files.keys.toList()..sort();
  final out = BytesBuilder(copy: false);
  for (final path in paths) {
    final name = utf8.encode(path);
    final bytes = files[path]!;
    out
      ..add(_u32(name.length))
      ..add(name)
      ..add(_u32(bytes.length))
      ..add(bytes);
  }
  return sha256.convert(out.takeBytes()).toString();
}

Uint8List _u32(int n) => Uint8List(4)..buffer.asByteData().setUint32(0, n);

/// [files] as a `.zip` package, which `readExtensionPackage` reads back.
Uint8List packExtension(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final path in files.keys.toList()..sort()) {
    archive.addFile(ArchiveFile.bytes(path, files[path]!));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// An installed extension and its files, as an export reads them.
typedef ExtensionForBackup = ({
  WebExtensionEntry entry,
  Map<String, Uint8List> files,
});

/// Each way of carrying the library, ready to write, and how many bytes
/// each adds to the backup.
typedef ExtensionCarryOffer = ({
  int count,
  BackupExtensions references,
  int referencesBytes,
  BackupExtensions files,
  int filesBytes,
});

ExtensionCarryOffer offerExtensionCarry(List<ExtensionForBackup> library) {
  BackupExtension carried(ExtensionForBackup e, {required bool package}) =>
      BackupExtension(
        id: e.entry.id,
        name: e.entry.name,
        version: e.entry.version,
        fingerprint: extensionFingerprint(e.files),
        package: package ? packExtension(e.files) : null,
      );
  final references = BackupExtensions(
    carry: ExtensionCarry.references,
    extensions: [for (final e in library) carried(e, package: false)],
  );
  final files = BackupExtensions(
    carry: ExtensionCarry.files,
    extensions: [for (final e in library) carried(e, package: true)],
  );
  int bytes(BackupExtensions section) =>
      utf8.encode(jsonEncode(section.toJson())).length;
  return (
    count: library.length,
    references: references,
    referencesBytes: bytes(references),
    files: files,
    filesBytes: bytes(files),
  );
}

/// The section a backup carries for [carry]; none to leave them out.
BackupExtensions? extensionSectionFor(
  ExtensionCarry carry, {
  required ExtensionCarryOffer offer,
}) => switch (carry) {
  ExtensionCarry.leaveOut => null,
  ExtensionCarry.references => offer.references,
  ExtensionCarry.files => offer.files,
};

/// What an import does with a backup's extensions: those this device
/// already has, by the backup's id; those it can add from their files; and
/// those it can do neither for.
typedef ExtensionRelinkPlan = ({
  Map<WebExtensionId, WebExtensionId> linked,
  List<BackupExtension> toAdd,
  List<BackupExtension> missing,
});

/// [incoming] against this device's library, given as each installed
/// extension's fingerprint.
ExtensionRelinkPlan planExtensionRelink(
  BackupExtensions incoming, {
  required Map<String, WebExtensionId> library,
}) {
  final linked = <WebExtensionId, WebExtensionId>{};
  final toAdd = <BackupExtension>[];
  final missing = <BackupExtension>[];
  for (final e in incoming.extensions) {
    if (library[e.fingerprint] case final id?) {
      linked[e.id] = id;
    } else if (e.package != null) {
      toAdd.add(e);
    } else {
      missing.add(e);
    }
  }
  return (linked: linked, toAdd: toAdd, missing: missing);
}

/// A site's [choices] as the backup made them, kept only for the
/// extensions the import linked, under their ids on this device.
Map<WebExtensionId, bool> relinkChoices(
  Map<WebExtensionId, bool> choices, {
  required Map<WebExtensionId, WebExtensionId> links,
}) => {
  for (final MapEntry(:key, :value) in choices.entries)
    ?links[key]: value,
};
