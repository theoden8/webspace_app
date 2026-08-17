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
