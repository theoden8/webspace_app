import 'dart:io' as io;

bool get hostIsAndroid => io.Platform.isAndroid;
bool get hostIsIOS => io.Platform.isIOS;
bool get hostIsMacOS => io.Platform.isMacOS;
bool get hostIsLinux => io.Platform.isLinux;
bool get hostIsWindows => io.Platform.isWindows;
bool get hostIsFuchsia => io.Platform.isFuchsia;
String get hostOperatingSystem => io.Platform.operatingSystem;
String get hostOperatingSystemVersion => io.Platform.operatingSystemVersion;

/// Write [bytes] to [path]. Unavailable on web; callers there must route
/// through the browser's own download path instead.
Future<void> hostWriteBytes(String path, List<int> bytes) =>
    io.File(path).writeAsBytes(bytes);
