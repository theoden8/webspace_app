import 'dart:convert';
import 'dart:io' as io;

import 'dart:typed_data';

import 'package:path_provider/path_provider.dart' as pp;

bool get hostIsAndroid => io.Platform.isAndroid;
bool get hostIsIOS => io.Platform.isIOS;
bool get hostIsMacOS => io.Platform.isMacOS;
bool get hostIsLinux => io.Platform.isLinux;
bool get hostIsWindows => io.Platform.isWindows;
bool get hostIsFuchsia => io.Platform.isFuchsia;
Map<String, String> get hostEnvironment => io.Platform.environment;
String get hostOperatingSystem => io.Platform.operatingSystem;
String get hostOperatingSystemVersion => io.Platform.operatingSystemVersion;

/// Write [bytes] to [path]. Unavailable on web; callers there must route
/// through the browser's own download path instead.
Future<void> hostWriteBytes(String path, List<int> bytes) =>
    io.File(path).writeAsBytes(bytes);

/// True when [host] resolves. Used as a cheap online check.
Future<bool> hostCanResolve(String host,
    {Duration timeout = const Duration(seconds: 3)}) async {
  try {
    final result = await io.InternetAddress.lookup(host).timeout(timeout);
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Read a cache file from the app documents directory, or null when absent.
Future<String?> hostReadDocumentText(String name) async {
  final dir = await pp.getApplicationDocumentsDirectory();
  final file = io.File('${dir.path}/$name');
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<void> hostWriteDocumentText(String name, String contents) async {
  final dir = await pp.getApplicationDocumentsDirectory();
  await io.File('${dir.path}/$name').writeAsString(contents);
}

/// Read an absolute path chosen by the OS file picker.
Future<Uint8List> hostReadFileBytes(String path) => io.File(path).readAsBytes();

Future<void> hostWriteFileBytes(String path, List<int> bytes) =>
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

/// Absolute path of the app documents directory.
Future<String> hostDocumentsPath() async =>
    (await pp.getApplicationDocumentsDirectory()).path;

/// The platform's gzip / zlib decoders, as plain converters so callers keep
/// their own bounded-inflation guards.
Converter<List<int>, List<int>> get hostGzipDecoder => io.gzip.decoder;
Converter<List<int>, List<int>> get hostZlibDecoder => io.zlib.decoder;
Converter<List<int>, List<int>> get hostGzipEncoder => io.gzip.encoder;

/// Synchronous read, for the compute-isolate parse paths that take a path.
String hostReadFileTextSync(String path) => io.File(path).readAsStringSync();

Future<void> hostWriteFileText(String path, String contents) =>
    io.File(path).writeAsString(contents);

Future<String> hostReadFileText(String path) => io.File(path).readAsString();

/// Whether a candidate icon URL can be checked with a HEAD request before use.
/// True natively; on web the response is unreadable across origins, so the
/// check would reject every icon it is meant to validate.
const bool hostCanReadCrossOriginResponses = true;
