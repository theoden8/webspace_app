import 'dart:convert';
import 'dart:typed_data';

import 'package:webspace/settings/web_extension.dart';

/// How a settings backup carries the extension library (WEBEXT-011).
enum ExtensionCarry {
  /// Not at all: the default.
  leaveOut,

  /// Each extension's name, version and fingerprint, relinked on import to
  /// one the device already has.
  references,

  /// Each extension's package, added on import.
  files,
}

/// One extension as a backup carries it. [package] is set only when the
/// backup carries files.
final class BackupExtension {
  const BackupExtension({
    required this.id,
    required this.name,
    required this.version,
    required this.fingerprint,
    required this.package,
  });

  /// Its id on the device that exported it, which the sites' choices name.
  final WebExtensionId id;
  final String name;
  final String version;

  /// The SHA-256 of its files (`extensionFingerprint`), the same on every
  /// device that has the same files.
  final String fingerprint;

  /// Its files as a `.zip` package.
  final Uint8List? package;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'fingerprint': fingerprint,
    if (package case final bytes?) 'package': base64Encode(bytes),
  };

  /// Null when [json] names no valid id or fingerprint; a wrong-typed
  /// field reads as absent.
  static BackupExtension? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = WebExtensionId.parse(json['id']);
    final fingerprint = switch (json['fingerprint']) {
      final String f when _fingerprintPattern.hasMatch(f) => f,
      _ => null,
    };
    if (id == null || fingerprint == null) return null;
    return BackupExtension(
      id: id,
      name: switch (json['name']) {
        final String s => s,
        _ => id,
      },
      version: switch (json['version']) {
        final String s => s,
        _ => '',
      },
      fingerprint: fingerprint,
      package: switch (json['package']) {
        final String s => _decodeBase64(s),
        _ => null,
      },
    );
  }

  static final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

  static Uint8List? _decodeBase64(String s) {
    try {
      return base64Decode(s);
    } on FormatException {
      return null;
    }
  }
}

/// The extensions a backup carries and how.
final class BackupExtensions {
  const BackupExtensions({required this.carry, required this.extensions})
    : assert(
        carry != ExtensionCarry.leaveOut,
        'a backup that leaves extensions out has no section',
      );

  final ExtensionCarry carry;
  final List<BackupExtension> extensions;

  Map<String, Object?> toJson() => {
    'carry': carry.name,
    'extensions': [for (final e in extensions) e.toJson()],
  };

  /// Null for anything but a section with a known carry; an entry that
  /// does not read is skipped, and a files entry without its package reads
  /// as a reference.
  static BackupExtensions? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final carry = switch (json['carry']) {
      'references' => ExtensionCarry.references,
      'files' => ExtensionCarry.files,
      _ => null,
    };
    if (carry == null) return null;
    return BackupExtensions(
      carry: carry,
      extensions: switch (json['extensions']) {
        final List<Object?> list => [
          for (final e in list) ?BackupExtension.fromJson(e),
        ],
        _ => const [],
      },
    );
  }
}
