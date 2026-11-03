import 'dart:io';

/// The notices of the libraries a Linux package bundles beside the app
/// (LICENSE-003): every `<name>/copyright` under the package's doc
/// directory, a Debian-format file that linux/install_notices.sh writes for
/// the libraries the package builds from source and that a staged Debian
/// package brings with it, followed by the licence files beside it. Empty
/// where the app runs on the system's own libraries.
Future<List<(String, String)>> bundledNotices() =>
    bundledNoticesIn(docs: bundledDocsDir(environment: Platform.environment));

/// Where the package the app runs from keeps its libraries' notices: a
/// snap's `usr/share/doc`, a flatpak's `/app/share/doc`, or null outside
/// both.
String? bundledDocsDir({required Map<String, String> environment}) {
  final snap = environment['SNAP'];
  if (snap != null && snap.isNotEmpty) return '$snap/usr/share/doc';
  if (environment.containsKey('FLATPAK_ID')) return '/app/share/doc';
  return null;
}

/// Each notice under [docs], named for its directory, in name order.
Future<List<(String, String)>> bundledNoticesIn({required String? docs}) async {
  if (docs == null) return const [];
  final root = Directory(docs);
  if (!await root.exists()) return const [];
  final out = <(String, String)>[];
  await for (final entry in root.list()) {
    if (entry is! Directory) continue;
    final copyright = File('${entry.path}/copyright');
    if (!await copyright.exists()) continue;
    final text = StringBuffer(await copyright.readAsString());
    final licences = Directory('${entry.path}/licences');
    if (await licences.exists()) {
      final files = await licences
          .list(recursive: true)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final name = file.path.substring(licences.path.length + 1);
        text
          ..write('\n\n--- $name ---\n\n')
          ..write(await file.readAsString());
      }
    }
    out.add((
      '${entry.path.split('/').last} (bundled library)',
      text.toString(),
    ));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}
