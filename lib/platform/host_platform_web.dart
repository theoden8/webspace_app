import 'dart:typed_data';

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

/// Web has no socket API here; the design gallery is always treated as online.
Future<bool> hostCanResolve(String host,
        {Duration timeout = const Duration(seconds: 3)}) async =>
    true;

/// No documents directory on web: downloaded caches simply stay empty, which
/// leaves the depending services in their no-data state.
Future<String?> hostReadDocumentText(String name) async => null;

Future<void> hostWriteDocumentText(String name, String contents) async {}

/// The web file picker hands bytes back directly; there is no path to read.
Future<Uint8List> hostReadFileBytes(String path) =>
    throw UnsupportedError('hostReadFileBytes is not available on web');
