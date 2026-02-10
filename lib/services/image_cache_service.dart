import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage image cache persistence across app sessions.
/// Clears the cache on app upgrades to ensure fresh images.
class ImageCacheService {
  static const String _lastVersionKey = 'image_cache_version';

  /// Clears image cache if the app version has changed.
  /// Call this on app startup before any images are loaded.
  static Future<void> clearCacheOnUpgrade() async {
    final prefs = await SharedPreferences.getInstance();
    final packageInfo = await PackageInfo.fromPlatform();

    final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    final lastVersion = prefs.getString(_lastVersionKey);

    if (lastVersion != null && lastVersion != currentVersion) {
      // Version changed - clear the image cache
      await DefaultCacheManager().emptyCache();
    }

    // Store current version
    await prefs.setString(_lastVersionKey, currentVersion);
  }
}
