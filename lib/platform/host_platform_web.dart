import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

// Web has no host platform in the dart:io sense: nothing here is Android, iOS
// or macOS, so every per-OS branch takes its non-native path.
bool get hostIsAndroid => false;
bool get hostIsIOS => false;
bool get hostIsMacOS => false;
bool get hostIsLinux => false;
bool get hostIsWindows => false;
bool get hostIsFuchsia => false;
const Map<String, String> hostEnvironment = <String, String>{};
String get hostOperatingSystem => 'web';
String get hostOperatingSystemVersion => '';

Future<void> hostWriteBytes(String path, List<int> bytes) =>
    throw UnsupportedError('hostWriteBytes is not available on web');

/// A browser exposes no resolver, so this reports "cannot answer" instead of
/// guessing. The web target does not run the webview, so no page JS drives an
/// outbound fetch here in the first place.
Future<List<String>?> hostLookupAddresses(String host) async => null;

/// Web has no socket API here; the design gallery is always treated as online.
Future<bool> hostCanResolve(String host,
        {Duration timeout = const Duration(seconds: 3)}) async =>
    true;

/// Downloads do not run in the design gallery; the browser client exists only
/// so the download engine's pure logic stays reachable from a web compile.
http.Client hostDirectDownloadClient() => http.Client();

/// The web file picker hands bytes back directly; there is no path to read.
Future<Uint8List> hostReadFileBytes(String path) =>
    throw UnsupportedError('hostReadFileBytes is not available on web');

Future<void> hostWriteFileBytes(String path, List<int> bytes) async {}

Future<bool> hostFileExists(String path) async => false;

Future<int> hostFileLength(String path) async => 0;

Future<void> hostDeleteFile(String path) async {}

Future<void> hostEnsureDirectory(String path) async {}

Future<void> hostDeleteDirectory(String path) async {}

/// No zlib on web. These exist so compression call sites compile; using one
/// throws rather than silently returning the input, which would hand a caller
/// compressed bytes labelled as plain.
class _UnsupportedCodec extends Converter<List<int>, List<int>> {
  const _UnsupportedCodec(this.name);

  final String name;

  @override
  List<int> convert(List<int> input) =>
      throw UnsupportedError('$name is not available on web');
}

Converter<List<int>, List<int>> get hostGzipDecoder => const _UnsupportedCodec('gzip.decoder');
Converter<List<int>, List<int>> get hostZlibDecoder => const _UnsupportedCodec('zlib.decoder');
Converter<List<int>, List<int>> get hostGzipEncoder => const _UnsupportedCodec('gzip.encoder');

String hostReadFileTextSync(String path) =>
    throw UnsupportedError('hostReadFileTextSync is not available on web');

Future<void> hostWriteFileText(String path, String contents) async {}

Future<String> hostReadFileText(String path) =>
    throw UnsupportedError('hostReadFileText is not available on web');

/// See the io half: cross-origin favicon responses are unreadable from a page,
/// so the candidate is used optimistically and the <img> decides.
const bool hostCanReadCrossOriginResponses = false;
