// Web has no host platform in the dart:io sense: nothing here is Android, iOS
// or macOS, so every per-OS branch takes its non-native path.
bool get hostIsAndroid => false;
bool get hostIsIOS => false;
bool get hostIsMacOS => false;
bool get hostIsLinux => false;
bool get hostIsWindows => false;
bool get hostIsFuchsia => false;
String get hostOperatingSystem => 'web';
String get hostOperatingSystemVersion => '';

Future<void> hostWriteBytes(String path, List<int> bytes) =>
    throw UnsupportedError('hostWriteBytes is not available on web');
