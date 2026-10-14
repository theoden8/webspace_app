import 'package:webspace/settings/site_ids.dart';

/// What a site's container is keyed by: an app-tier site's own [SiteId], or
/// for an archive-tier site an opaque id derived from the archive key, so its
/// store names no site on disk (ARCH-007).
extension type const ContainerKey._(String raw) implements String {
  ContainerKey.ofSite(SiteId site) : raw = site;

  /// A key as it is spelled on disk: an archive-tier site's opaque id, as
  /// `ArchiveController` derives it, or one the native store lists.
  factory ContainerKey.named(String raw) {
    assert(SiteId.parse(raw) != null, 'a container key is path-safe: $raw');
    return ContainerKey._(raw);
  }
}

/// What the native store calls a container, `ws-<key>`: what a webview binds
/// by (`InAppWebViewSettings.containerId`) and every container operation
/// names. Made from a [ContainerKey] only, so the prefix has one owner.
extension type const ContainerName._(String raw) implements String {
  ContainerName.of(ContainerKey key) : raw = '$_prefix$key';

  static const _prefix = 'ws-';

  /// A name the native store listed; null for one this app did not make.
  static ContainerName? parse(String raw) =>
      raw.startsWith(_prefix) ? ContainerName._(raw) : null;

  ContainerKey get key => ContainerKey.named(raw.substring(_prefix.length));
}
