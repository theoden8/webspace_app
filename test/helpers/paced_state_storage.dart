import 'dart:typed_data';

import 'package:webspace/services/activation_step.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/webview_state_storage.dart';

/// [WebViewStateStorage] in memory whose every call first awaits [pace], so
/// a test that schedules the platform's replies decides when each one lands,
/// as it does through `MockCookieManager.pace`. A call takes effect when its
/// reply lands.
final class PacedStateStorage implements WebViewStateStorage {
  final Map<String, Uint8List> _files = {};

  Future<void> Function(PlatformCall call)? pace;

  /// Told of each write as it lands.
  void Function(String key, {required Uint8List state})? onSave;

  /// The stored bytes by state key.
  Map<String, Uint8List> get files => Map.unmodifiable(_files);

  @override
  Future<bool> saveState(String key, {required Uint8List state}) async {
    await pace?.call(PlatformCall.navStateSave);
    if (state.isEmpty) return false;
    _files[key] = state;
    onSave?.call(key, state: state);
    return true;
  }

  @override
  Future<Uint8List?> loadState(String key) async {
    await pace?.call(PlatformCall.navStateLoad);
    return _files[key];
  }

  @override
  Future<void> removeState(String key) async {
    await pace?.call(PlatformCall.navStateRemove);
    _files.remove(key);
  }

  @override
  Future<int> removeStatesForSite(SiteId siteId) async {
    await pace?.call(PlatformCall.navStateRemoveForSite);
    final doomed = [
      for (final k in _files.keys)
        if (k.startsWith('$siteId.')) k,
    ];
    doomed.forEach(_files.remove);
    return doomed.length;
  }

  @override
  Future<int> removeOrphans(Set<String> activeKeys) async {
    await pace?.call(PlatformCall.navStateRemoveOrphans);
    final doomed = [
      for (final k in _files.keys)
        if (!activeKeys.contains(k)) k,
    ];
    doomed.forEach(_files.remove);
    return doomed.length;
  }

  @override
  Future<Set<String>> siteIds() async {
    await pace?.call(PlatformCall.navStateSiteIds);
    return {..._files.keys};
  }
}
