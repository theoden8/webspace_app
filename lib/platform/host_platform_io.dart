import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';


export 'dart:io' show IOException;

bool get hostIsAndroid => io.Platform.isAndroid;
bool get hostIsIOS => io.Platform.isIOS;
bool get hostIsMacOS => io.Platform.isMacOS;
bool get hostIsLinux => io.Platform.isLinux;
bool get hostIsWindows => io.Platform.isWindows;

/// A desktop OS: a window, a mouse and a hardware keyboard.
bool get hostIsDesktop => hostIsMacOS || hostIsLinux || hostIsWindows;
Map<String, String> get hostEnvironment => io.Platform.environment;
String get hostOperatingSystem => io.Platform.operatingSystem;
String get hostOperatingSystemVersion => io.Platform.operatingSystemVersion;

/// Write [bytes] to [path]. Unavailable on web; callers there must route
/// through the browser's own download path instead.
Future<void> hostWriteBytes(String path, {required List<int> bytes}) =>
    io.File(path).writeAsBytes(bytes);

/// [host]'s numeric addresses. Throws [io.SocketException] when the name
/// does not resolve, which a caller judging the destination reads as "no
/// answer" rather than "public".
Future<List<String>?> hostLookupAddresses(String host) async =>
    [for (final address in await io.InternetAddress.lookup(host)) address.address];

/// True when [host] resolves. Used as a cheap online check.
Future<bool> hostCanResolve(String host,
    {Duration timeout = const Duration(seconds: 3)}) async {
  try {
    final addresses = await hostLookupAddresses(host).timeout(timeout);
    return addresses != null && addresses.isNotEmpty;
  } on io.SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

/// Read an absolute path chosen by the OS file picker.
Future<Uint8List> hostReadFileBytes(String path) => io.File(path).readAsBytes();

Future<void> hostWriteFileBytes(String path, {required List<int> bytes}) =>
    io.File(path).writeAsBytes(bytes);

Future<bool> hostFileExists(String path) => io.File(path).exists();

/// Size in bytes, or 0 when the file is gone.
Future<int> hostFileLength(String path) async {
  final file = io.File(path);
  return await file.exists() ? file.length() : 0;
}

Future<void> hostDeleteFile(String path) async {
  final file = io.File(path);
  if (await file.exists()) await file.delete();
}

Future<void> hostEnsureDirectory(String path) async {
  final dir = io.Directory(path);
  if (!await dir.exists()) await dir.create(recursive: true);
}

Future<void> hostDeleteDirectory(String path) async {
  final dir = io.Directory(path);
  if (await dir.exists()) await dir.delete(recursive: true);
}

/// Moves the directory at [path] to [to], which must not exist.
Future<void> hostRenameDirectory(String path, {required String to}) async {
  await io.Directory(path).rename(to);
}

/// The names of the directories directly under [path]; none when it is
/// absent.
Future<List<String>> hostListDirectoryNames(String path) async {
  final dir = io.Directory(path);
  if (!await dir.exists()) return const [];
  final names = <String>[];
  await for (final entry in dir.list(followLinks: false)) {
    if (entry is io.Directory) {
      names.add(entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty));
    }
  }
  return names;
}

/// The path, relative to [path] and joined by `/`, of every file under it;
/// none when it is absent.
Future<List<String>> hostListFilesUnder(String path) async {
  final dir = io.Directory(path);
  if (!await dir.exists()) return const [];
  final root = dir.absolute.uri.pathSegments.where((s) => s.isNotEmpty).length;
  final paths = <String>[];
  await for (final entry in dir.list(recursive: true, followLinks: false)) {
    if (entry is io.File) {
      paths.add(entry.absolute.uri.pathSegments.skip(root).join('/'));
    }
  }
  return paths;
}

/// The platform's gzip / zlib decoders, as plain converters so callers keep
/// their own bounded-inflation guards.
Converter<List<int>, List<int>> get hostGzipDecoder => io.gzip.decoder;
Converter<List<int>, List<int>> get hostZlibDecoder => io.zlib.decoder;

/// Raw deflate, as a ZIP archive's entries hold it: no zlib header.
Converter<List<int>, List<int>> get hostDeflateDecoder =>
    io.ZLibDecoder(raw: true);
Converter<List<int>, List<int>> get hostGzipEncoder => io.gzip.encoder;

/// Synchronous read, for the compute-isolate parse paths that take a path.
String hostReadFileTextSync(String path) => io.File(path).readAsStringSync();

Future<void> hostWriteFileText(String path, {required String contents}) =>
    io.File(path).writeAsString(contents);

Future<String> hostReadFileText(String path) => io.File(path).readAsString();

/// Whether a candidate icon URL can be checked with a HEAD request before use.
/// True natively; on web the response is unreadable across origins, so the
/// check would reject every icon it is meant to validate.
const bool hostCanReadCrossOriginResponses = true;
