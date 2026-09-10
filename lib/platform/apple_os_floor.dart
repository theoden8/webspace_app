/// The flutter_inappwebview fork binds per-site containers
/// (`WKWebsiteDataStore(forIdentifier:)`) and per-site proxies
/// (`proxyConfigurations`) behind `#available(iOS 17.0, macOS 14.0, *)` and
/// silently no-ops below it, while the app's deployment floors are iOS 15 and
/// macOS 10.15. `io.Platform.operatingSystemVersion` reads
/// `Version 16.7.2 (Build 20H115)` on both platforms; the major version
/// decides. An unparseable string counts as below the floor: the legacy
/// engine is the safe side.
bool appleOsMeetsFloor(
  String operatingSystemVersion, {
  required bool isIOS,
}) {
  final match = RegExp(r'(\d+)(?:\.\d+)*').firstMatch(operatingSystemVersion);
  if (match == null) return false;
  final major = int.tryParse(match.group(1)!) ?? 0;
  return major >= (isIOS ? 17 : 14);
}
